const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: HICUM/L2 v3.2.0 (5-Terminal Electrothermal SiGe HBT)
//
// External: c (collector), b (base), e (emitter), s (substrate), tnode (thermal)
// Internal: ci (intrinsic collector), bi (intrinsic base),
//           bx (perimeter base B*), ei (intrinsic emitter),
//           si (intrinsic substrate), xf (NQS transfer current node),
//           xf1, xf2 (NQS minority charge nodes)
// ============================================================================

pub const U = enum(u8) {
    c, //  0 - external collector
    b, //  1 - external base
    e, //  2 - external emitter
    s, //  3 - external substrate
    tnode, //  4 - external thermal node
    ci, //  5 - intrinsic collector (internal)
    bi, //  6 - intrinsic base (internal)
    bx, //  7 - perimeter base B* (internal)
    ei, //  8 - intrinsic emitter (internal)
    si, //  9 - intrinsic substrate (internal)
    xf, // 10 - NQS transfer current node (internal)
    xf1, // 11 - NQS minority charge node 1 (internal)
    xf2, // 12 - NQS minority charge node 2 (internal)
};

pub const num_ports: usize = 5;

// ============================================================================
// Model Parameters -- every parameter from HICUM/L2 v3.2.0
// ============================================================================

pub const Model = struct {
    // --- Device type ---
    type_: i32 = 1, // +1 = NPN, -1 = PNP

    // --- 3.1 Transfer Current ---
    c10: f32 = 2.0e-30, // GICCR constant
    qp0: f32 = 2.0e-14, // Zero-bias hole charge
    hf0: f32 = 1.0, // Low-current minority charge weight
    hfe: f32 = 1.0, // Emitter minority charge weight (HBT)
    hfb: f32 = 1.0, // Base minority charge weight (HBT) -- reserved, not used in simplified model
    hfc: f32 = 1.0, // Collector minority charge weight (HBT)
    hr0c: f32 = 1.0, // Reverse minority charge weight (HBT) -- same as h_r0
    hjei0: f32 = 1.0, // BE depletion charge weight (HBT)
    ahjei: f32 = 0.0, // Slope factor of h_jEi(V_BE)
    rhjei: f32 = 1.0, // Smoothing factor for h_jEi at high forward bias
    hjci: f32 = 1.0, // BC depletion charge weight (HBT)
    mcf: f32 = 1.0, // Non-ideality factor (III-V HBTs)

    // --- 3.2 Base Current: B-E Components ---
    ibeis: f32 = 1.0e-18, // Internal BE saturation current
    mbei: f32 = 1.0, // Internal BE current ideality factor
    ireis: f32 = 0.0, // Internal BE recombination saturation current
    mrei: f32 = 2.0, // Internal BE recombination ideality factor
    ibeps: f32 = 0.0, // Peripheral BE saturation current
    mbep: f32 = 1.0, // Peripheral BE current ideality factor
    ireps: f32 = 0.0, // Peripheral BE recombination saturation current
    mrep: f32 = 2.0, // Peripheral BE recombination ideality factor
    tbhrec: f32 = 0.0, // Base current recombination time at BC barrier (0=inf)

    // --- 3.3 Base Current: B-C Components ---
    ibcis: f32 = 1.0e-16, // Internal BC saturation current
    mbci: f32 = 1.0, // Internal BC current ideality factor
    ibcxs: f32 = 0.0, // External BC saturation current
    mbcx: f32 = 1.0, // External BC current ideality factor

    // --- 3.4 BE Tunnelling Current ---
    ibetat0: f32 = 0.0, // BE TAT reference current
    vbetat: f32 = 1.0, // BE TAT voltage parameter
    ibets: f32 = 0.0, // BE BtBT saturation current
    abet: f32 = 40.0, // Exponent factor for BE BtBT
    tunode: i32 = 1, // BtBT node connection (0=internal, 1=perimeter)
    ibcts: f32 = 1.0, // BC BtBT saturation current
    abct: f32 = 40.0, // Exponent factor for BC BtBT

    // --- 3.5 BC Avalanche ---
    favl: f32 = 0.0, // Avalanche current factor
    qavl: f32 = 0.0, // Exponent factor for avalanche
    kavl: f32 = 0.0, // Strong avalanche factor
    hcavl: f32 = 0.0, // Current-dependent avalanche model flag
    hvdavl: f32 = 0.0, // Current-dependent avalanche (spatial doping)

    // --- 3.6 Series Resistances ---
    rbi0: f32 = 0.0, // Zero-bias internal base resistance
    rbx: f32 = 0.0, // External base series resistance
    fgeo: f32 = 0.6557, // Geometry factor for emitter current crowding
    fdqr0: f32 = 0.0, // Correction factor for modulation by SCL
    fcrbi: f32 = 0.0, // Ratio of HF shunt to total internal cap
    fqi: f32 = 1.0, // Ratio of internal to total minority charge
    re: f32 = 0.0, // Emitter series resistance
    rcx: f32 = 0.0, // External collector series resistance

    // --- 3.7 Substrate Transistor ---
    itss: f32 = 0.0, // Substrate transistor transfer current saturation
    msf: f32 = 1.0, // Forward ideality factor (m_Sr = m_Sf)
    iscs: f32 = 0.0, // Saturation current of C-S diode
    msc: f32 = 1.0, // Ideality factor of C-S diode
    tsf: f32 = 0.0, // Transit time (forward operation)

    // --- 3.8 Intra-Device Substrate Coupling ---
    rsu: f32 = 0.0, // Substrate series resistance
    csu: f32 = 0.0, // Shunt capacitance

    // --- 3.9 Depletion Charge Components ---
    cjei0: f32 = 1.0e-20, // Internal BE zero-bias depletion cap
    vdei: f32 = 0.9, // Internal BE built-in potential
    zei: f32 = 0.5, // Internal BE grading coefficient
    ajei: f32 = 2.5, // Ratio max/zero-bias internal BE cap
    cjep0: f32 = 1.0e-20, // Peripheral BE zero-bias depletion cap
    vdep: f32 = 0.9, // Peripheral BE built-in potential
    zep: f32 = 0.5, // Peripheral BE grading coefficient
    ajep: f32 = 2.5, // Ratio max/zero-bias peripheral BE cap
    cjci0: f32 = 1.0e-20, // Internal BC zero-bias depletion cap
    vdci: f32 = 0.7, // Internal BC built-in potential
    zci: f32 = 0.4, // Internal BC grading coefficient
    ajci: f32 = 2.4, // Ratio max/zero-bias internal BC cap
    vptci: f32 = 100.0, // Internal BC punch-through voltage
    cjcx0: f32 = 1.0e-20, // External BC zero-bias depletion cap
    vdcx: f32 = 0.7, // External BC built-in potential
    zcx: f32 = 0.4, // External BC grading coefficient
    ajcx: f32 = 2.4, // Ratio max/zero-bias external BC cap
    vptcx: f32 = 100.0, // External BC punch-through voltage
    cjs0: f32 = 0.0, // C-S zero-bias depletion cap (bottom)
    vds: f32 = 0.6, // C-S built-in potential
    zs: f32 = 0.5, // C-S grading coefficient
    ajs: f32 = 2.4, // Ratio max/zero-bias C-S cap
    vpts: f32 = 100.0, // C-S punch-through voltage
    cscp0: f32 = 0.0, // Peripheral C-S zero-bias depletion cap
    vdsp: f32 = 0.6, // Peripheral C-S built-in potential
    zsp: f32 = 0.5, // Peripheral C-S grading coefficient
    vptsp: f32 = 100.0, // Peripheral C-S punch-through voltage

    // --- 3.10 Minority Charge Storage ---
    t0: f32 = 0.0, // Low-current forward transit time at Vbc=0
    dt0h: f32 = 0.0, // Time constant for base/BC SCL width modulation
    tbvl: f32 = 0.0, // Time constant for carrier jam at low Vce
    tef0: f32 = 0.0, // Neutral emitter storage time
    gtfe: f32 = 1.0, // Exponent for current-dep neutral emitter storage
    thcs: f32 = 0.0, // Saturation time constant at high current
    ahc: f32 = 0.1, // Smoothing factor for base+collector transit time
    fthc: f32 = 0.0, // Partitioning factor for base/collector
    rci0: f32 = 150.0, // Internal collector resistance at low E field
    vlim: f32 = 0.5, // Voltage separating ohmic/saturation velocity
    vces: f32 = 0.1, // Internal C-E saturation voltage
    vdck: f32 = 0.0, // Internal BC built-in voltage (v3.1+)
    avcsm: f32 = 1.921812, // Smoothing factor for effective internal Vc
    vpt: f32 = 0.0, // Collector punch-through voltage (0=inf)
    delck: f32 = 2.0, // Field dependence factor for Ick
    aick: f32 = 1.0e-3, // Smoothing factor for Ick punch-through
    tr: f32 = 0.0, // Storage time for reverse operation
    vcbar: f32 = 0.0, // BC barrier voltage
    icbar: f32 = 0.0, // Current normalization for barrier
    acbar: f32 = 0.01, // Smoothing parameter for barrier bias dep

    // --- 3.11 Parasitic Isolation Capacitances ---
    cbepar: f32 = 0.0, // Total parasitic BE cap
    fbepar: f32 = 1.0, // Partitioning factor for parasitic BE cap
    cbcpar: f32 = 0.0, // Total parasitic BC cap
    fbcpar: f32 = 0.0, // Partitioning factor for parasitic BC cap
    ccepar: f32 = 0.0, // Total parasitic CE cap

    // --- 3.12 Vertical NQS ---
    alqf: f32 = 0.167, // Additional delay time factor for minority charge
    alit: f32 = 0.333, // Additional delay time factor for transfer current
    flnqs: i32 = 0, // Flag for vertical NQS (0=off, 1=on)

    // --- 3.13 Noise ---
    kf: f32 = 0.0, // Flicker noise coefficient
    af: f32 = 2.0, // Flicker noise exponent
    cfbe: i32 = -1, // Flicker noise source location (-1=internal, -2=perimeter)
    kfre: f32 = 0.0, // Emitter resistance flicker noise coefficient
    afre: f32 = 2.0, // Emitter resistance flicker noise exponent
    flcono: i32 = 0, // Correlated noise flag (0=off, 1=on)

    // --- 3.14 Lateral Geometry Scaling ---
    latb: f32 = 0.0, // Scaling factor for collector charge in b_E direction
    latl: f32 = 0.0, // Scaling factor for collector charge in l_E direction

    // --- 3.15 Temperature Dependence ---
    vgb: f32 = 1.17, // Bandgap voltage extrapolated to 0K
    f1vg: f32 = -1.02377e-4, // K1 coefficient in T-dep bandgap
    f2vg: f32 = 4.3215e-4, // K2 coefficient in T-dep bandgap
    zetact: f32 = 3.0, // Exponent in transfer current T-dep
    vge: f32 = 1.17, // Effective emitter bandgap voltage (default=VGB)
    zetabet: f32 = 3.5, // Exponent in BE junction current T-dep
    vgc: f32 = 1.17, // Effective collector bandgap voltage (default=VGB)
    vgs: f32 = 1.17, // Effective substrate bandgap voltage (default=VGB)
    dvgbe: f32 = 0.0, // Bandgap diff between neutral base and BE SCR
    zetahjei: f32 = 1.0, // Temperature coefficient for a_hjEi
    zetavgbe: f32 = 1.0, // Temperature coefficient for h_jEi0
    alt0: f32 = 0.0, // 1st-order relative TC of tau_0
    kt0: f32 = 0.0, // 2nd-order relative TC of tau_0
    zetaci: f32 = 0.0, // Temperature exponent for r_Ci0
    alvs: f32 = 0.0, // Relative TC of saturation drift velocity
    alces: f32 = 0.0, // Relative TC of V_CEs
    aldck: f32 = 0.0, // Relative TC of V_DCk
    zetarbi: f32 = 0.0, // Temperature exponent of internal base R
    zetarbx: f32 = 0.0, // Temperature exponent of external base R
    zetarcx: f32 = 0.0, // Temperature exponent of external collector R
    zetare: f32 = 0.0, // Temperature exponent of emitter R
    zetarth: f32 = 0.0, // Temperature exponent of thermal R
    alrth: f32 = 0.0, // 1st-order relative TC of Rth
    zetacx: f32 = 1.0, // Temperature exponent of mobility in substrate transit
    alfav: f32 = 0.0, // Relative TC for f_AVL
    alqav: f32 = 0.0, // Relative TC for q_AVL

    // --- 3.16 Self-Heating ---
    rth: f32 = 0.0, // Thermal resistance
    cth: f32 = 0.0, // Thermal capacitance
    flsh: i32 = 0, // Self-heating flag (0=off, 1=main, 2=all)

    // --- 3.17 Circuit Simulator Specific ---
    tnom: f32 = 27.0, // Reference temperature (degC)
    dt: f32 = 0.0, // Temperature offset
    flcomp: i32 = 310, // Compatibility flag / version
    minr: f32 = 0.0, // Minimum resistor value (simulator specific)
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    m: f32 = 1.0, // Multiplier
    dtemp: f32 = 0.0, // Instance temperature offset (degC)
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Thermal noise: rBx (b -- bx)
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.bx), .kind = .thermal },
    // Thermal noise: rBi (bx -- bi)
    .{ .row = @intFromEnum(U.bx), .col = @intFromEnum(U.bi), .kind = .thermal },
    // Thermal noise: rE (e -- ei)
    .{ .row = @intFromEnum(U.e), .col = @intFromEnum(U.ei), .kind = .thermal },
    // Thermal noise: rCx (c -- ci)
    .{ .row = @intFromEnum(U.c), .col = @intFromEnum(U.ci), .kind = .thermal },
    // Shot noise: transfer current (ci -- ei)
    .{ .row = @intFromEnum(U.ci), .col = @intFromEnum(U.ei), .kind = .shot },
    // Shot noise: internal BE junction (bi -- ei)
    .{ .row = @intFromEnum(U.bi), .col = @intFromEnum(U.ei), .kind = .shot },
    // Shot noise: peripheral BE junction (bx -- ei)
    .{ .row = @intFromEnum(U.bx), .col = @intFromEnum(U.ei), .kind = .shot },
    // Shot noise: internal BC junction (bi -- ci)
    .{ .row = @intFromEnum(U.bi), .col = @intFromEnum(U.ci), .kind = .shot },
    // Shot noise: external BC junction (bx -- ci)
    .{ .row = @intFromEnum(U.bx), .col = @intFromEnum(U.ci), .kind = .shot },
    // Shot noise: avalanche (ci -- bi)
    .{ .row = @intFromEnum(U.ci), .col = @intFromEnum(U.bi), .kind = .shot },
    // Shot noise: S-C diode (si -- ci)
    .{ .row = @intFromEnum(U.si), .col = @intFromEnum(U.ci), .kind = .shot },
    // Shot noise: BE tunnelling (bi -- ei) (Eq 2-157, BEt)
    .{ .row = @intFromEnum(U.bi), .col = @intFromEnum(U.ei), .kind = .shot },
    // Shot noise: BC tunnelling (bi -- ci) (Eq 2-157, BCt)
    .{ .row = @intFromEnum(U.bi), .col = @intFromEnum(U.ci), .kind = .shot },
    // Flicker noise: BE junction (bi -- ei or bx -- ei depending on cfbe)
    .{ .row = @intFromEnum(U.bi), .col = @intFromEnum(U.ei), .kind = .flicker },
};

// ============================================================================
// Physics constants
// ============================================================================

const gmin: f64 = 1.0e-12;
const a_fj: f64 = 1.921812; // = 4*ln(2)^2
const k_b: f64 = 8.617333e-5; // Boltzmann constant eV/K
const mg: f64 = 4.188; // m_g for Si (Eq 2-169)

// ============================================================================
// Temperature-Mapped Parameters (x-INDEPENDENT except self-heating dt_sh).
//
// Every quantity here is a pure function of model+instance params and the
// device temperature. The device temperature depends on x[tnode] ONLY when
// self-heating is active; that dependence is handled by passing dt_sh in as
// an f64 (see the "concerns" note in the migration record). All the
// heavy T-scaling below stays f64 -- it is bias-independent physics.
// ============================================================================

const TempParams = struct {
    // Environment
    vt_nom: f64,
    vt: f64,
    r_t: f64,
    ln_rt: f64,
    delta_t: f64,
    // Built-in voltages (BE/BC internal)
    vdei_t: f64,
    vdci_t: f64,
    // T-scaled caps
    cjei0_t: f64,
    cjci0_t: f64,
    ajei_t: f64,
    ajci_t: f64,
    // Saturation currents / transfer
    c10_t: f64,
    qp0_t: f64,
    ibeis_t: f64,
    ireis_t: f64,
    ibeps_t: f64,
    ireps_t: f64,
    ibcis_t: f64,
    ibcxs_t: f64,
    itss_t: f64,
    iscs_t: f64,
    // Resistances
    rbi0_t: f64,
    rbx_t: f64,
    rcx_t: f64,
    re_t: f64,
    rci0_t: f64,
    rth_t: f64,
    rsu_t: f64,
    // Collector / transit
    vlim_t: f64,
    vces_t: f64,
    vdck_t: f64,
    t0_t: f64,
    thcs_t: f64,
    tef0_t: f64,
    // Avalanche
    favl_t: f64,
    qavl_t: f64,
    // Weight factors
    hf0_t: f64,
    hjei0_t: f64,
    ahjei_t: f64,
    // Tunnelling
    ibets_t: f64,
    abet_t: f64,
    ibetat0_t: f64,
    ibcts_t: f64,
    abct_t: f64,
};

/// Compute all temperature-scaled parameters. `dt_sh` is the self-heating
/// temperature rise (0 when self-heating is off); it is passed as f64.
fn tempParams(model: *const Model, instance: *const Instance, dt_sh: f64) TempParams {
    const TNOM: f64 = @as(f64, model.tnom);
    const DT_M: f64 = @as(f64, model.dt);
    const dtemp_i: f64 = @as(f64, instance.dtemp);

    const VDEI: f64 = @as(f64, model.vdei);
    const ZEI: f64 = @as(f64, model.zei);
    const AJEI: f64 = @as(f64, model.ajei);
    const CJEI0: f64 = @as(f64, model.cjei0);
    const VDCI: f64 = @as(f64, model.vdci);
    const ZCI: f64 = @as(f64, model.zci);
    const AJCI: f64 = @as(f64, model.ajci);
    const CJCI0: f64 = @as(f64, model.cjci0);

    const C10: f64 = @as(f64, model.c10);
    const QP0: f64 = @as(f64, model.qp0);
    const HF0: f64 = @as(f64, model.hf0);
    const HJEI0: f64 = @as(f64, model.hjei0);
    const AHJEI: f64 = @as(f64, model.ahjei);
    const IBEIS: f64 = @as(f64, model.ibeis);
    const IREIS: f64 = @as(f64, model.ireis);
    const MREI: f64 = @as(f64, model.mrei);
    const IBEPS: f64 = @as(f64, model.ibeps);
    const IREPS: f64 = @as(f64, model.ireps);
    const MREP: f64 = @as(f64, model.mrep);
    const IBCIS: f64 = @as(f64, model.ibcis);
    const IBCXS: f64 = @as(f64, model.ibcxs);
    const ITSS: f64 = @as(f64, model.itss);
    const ISCS: f64 = @as(f64, model.iscs);

    const RBI0: f64 = @as(f64, model.rbi0);
    const RBX: f64 = @as(f64, model.rbx);
    const RCX: f64 = @as(f64, model.rcx);
    const RE: f64 = @as(f64, model.re);
    const RCI0: f64 = @as(f64, model.rci0);
    const RTH: f64 = @as(f64, model.rth);
    const RSU: f64 = @as(f64, model.rsu);

    const VLIM: f64 = @as(f64, model.vlim);
    const VCES: f64 = @as(f64, model.vces);
    const VDCK: f64 = @as(f64, model.vdck);
    const T0: f64 = @as(f64, model.t0);
    const THCS: f64 = @as(f64, model.thcs);
    const TEF0: f64 = @as(f64, model.tef0);

    const FAVL: f64 = @as(f64, model.favl);
    const QAVL: f64 = @as(f64, model.qavl);

    const IBETS: f64 = @as(f64, model.ibets);
    const ABET: f64 = @as(f64, model.abet);
    const IBETAT0: f64 = @as(f64, model.ibetat0);
    const VBETAT: f64 = @as(f64, model.vbetat);
    const IBCTS: f64 = @as(f64, model.ibcts);
    const ABCT: f64 = @as(f64, model.abct);

    const VGB: f64 = @as(f64, model.vgb);
    const F1VG: f64 = @as(f64, model.f1vg);
    const F2VG: f64 = @as(f64, model.f2vg);
    const ZETACT: f64 = @as(f64, model.zetact);
    const VGE: f64 = @as(f64, model.vge);
    const ZETABET: f64 = @as(f64, model.zetabet);
    const VGC: f64 = @as(f64, model.vgc);
    const DVGBE: f64 = @as(f64, model.dvgbe);
    const ZETAHJEI: f64 = @as(f64, model.zetahjei);
    const ZETAVGBE: f64 = @as(f64, model.zetavgbe);
    const ALT0: f64 = @as(f64, model.alt0);
    const KT0: f64 = @as(f64, model.kt0);
    const ZETACI: f64 = @as(f64, model.zetaci);
    const ALVS: f64 = @as(f64, model.alvs);
    const ALCES: f64 = @as(f64, model.alces);
    const ALDCK: f64 = @as(f64, model.aldck);
    const ZETARBI: f64 = @as(f64, model.zetarbi);
    const ZETARBX: f64 = @as(f64, model.zetarbx);
    const ZETARCX: f64 = @as(f64, model.zetarcx);
    const ZETARE: f64 = @as(f64, model.zetare);
    const ALFAV: f64 = @as(f64, model.alfav);
    const ALQAV: f64 = @as(f64, model.alqav);
    const ZETACX: f64 = @as(f64, model.zetacx);
    const ZETARTH: f64 = @as(f64, model.zetarth);
    const ALRTH: f64 = @as(f64, model.alrth);
    const VGS: f64 = @as(f64, model.vgs);

    // -- Temperature mapping --
    const t_nom_k = 273.15 + TNOM;
    const vt_nom = k_b * t_nom_k;
    const t_dev = t_nom_k + DT_M + dtemp_i + dt_sh;
    const vt = k_b * t_dev;
    const r_t = t_dev / t_nom_k;
    const delta_t = t_dev - t_nom_k;
    const ln_rt = @log(@max(r_t, 1.0e-30));

    // -- Bandgap voltage (Eq 2-165 to 2-167) --
    const k1 = F1VG * t_nom_k;
    const k2 = F2VG * t_nom_k + k1 * @log(@max(t_nom_k, 1.0e-30));
    const vgb_0 = VGB - k2;
    const vge_0 = VGE - k2;
    const vgc_0 = VGC - k2;
    const vgs_0 = VGS - k2;
    const vg_be_0 = (vgb_0 + vge_0) / 2.0;
    const vg_bc_0 = (vgb_0 + vgc_0) / 2.0;

    // -- Built-in voltages (Eq 2-195 to 2-198) --
    const vdei_j0 = 2.0 * vt_nom * @log(@max(@exp(@min(VDEI / (2.0 * vt_nom), 80.0)) - @exp(@min(-VDEI / (2.0 * vt_nom), 80.0)), 1.0e-30));
    const vdei_jt = vdei_j0 * r_t - mg * vt * ln_rt - vg_be_0 * (r_t - 1.0);
    const vdei_t = vdei_jt + 2.0 * vt * @log(@max(0.5 * (1.0 + @sqrt(@max(1.0 + 4.0 * @exp(@min(-vdei_jt / vt, 80.0)), 1.0e-30))), 1.0e-30));

    const vdci_j0 = 2.0 * vt_nom * @log(@max(@exp(@min(VDCI / (2.0 * vt_nom), 80.0)) - @exp(@min(-VDCI / (2.0 * vt_nom), 80.0)), 1.0e-30));
    const vdci_jt = vdci_j0 * r_t - mg * vt * ln_rt - vg_bc_0 * (r_t - 1.0);
    const vdci_t = vdci_jt + 2.0 * vt * @log(@max(0.5 * (1.0 + @sqrt(@max(1.0 + 4.0 * @exp(@min(-vdci_jt / vt, 80.0)), 1.0e-30))), 1.0e-30));

    // -- T-scaled capacitances (Eq 2-202, 2-203) --
    const cjei0_t = CJEI0 * @exp(ZEI * @log(@max(VDEI / vdei_t, 1.0e-30)));
    const cjci0_t = CJCI0 * @exp(ZCI * @log(@max(VDCI / vdci_t, 1.0e-30)));
    const ajei_t = AJEI * vdei_t / VDEI;
    const ajci_t = AJCI * vdci_t / VDCI;

    // -- T-scaled saturation currents --
    const c10_t = C10 * @exp(ZETACT * ln_rt + vgb_0 / vt * (r_t - 1.0));
    const qp0_t = QP0 * (2.0 - @exp(ZEI * @log(@max(vdei_t / VDEI, 1.0e-30))));

    const ibeis_t = IBEIS * @exp(ZETABET * ln_rt + vge_0 / vt * (r_t - 1.0));
    const ireis_t = IREIS * @exp(ZETABET / MREI * ln_rt + vge_0 / (MREI * vt) * (r_t - 1.0));
    const ibeps_t = IBEPS * @exp(ZETABET * ln_rt + vge_0 / vt * (r_t - 1.0));
    const ireps_t = IREPS * @exp(ZETABET / MREP * ln_rt + vge_0 / (MREP * vt) * (r_t - 1.0));

    const zeta_bcit = mg + 1.0 - ZETACI;
    const ibcis_t = IBCIS * @exp(zeta_bcit * ln_rt + vgc_0 / vt * (r_t - 1.0));
    const ibcxs_t = IBCXS * @exp(zeta_bcit * ln_rt + vgc_0 / vt * (r_t - 1.0));

    const zeta_bcxt = mg + 1.0 - ZETACX;
    const itss_t = ITSS * @exp(zeta_bcxt * ln_rt + vgc_0 / vt * (r_t - 1.0));
    const iscs_t = ISCS * @exp(zeta_bcxt * ln_rt + vgs_0 / vt * (r_t - 1.0));

    // -- Series resistances (Eq 2-204) --
    const rbi0_t = RBI0 * @exp(ZETARBI * ln_rt);
    const rbx_t = RBX * @exp(ZETARBX * ln_rt);
    const rcx_t = RCX * @exp(ZETARCX * ln_rt);
    const re_t = RE * @exp(ZETARE * ln_rt);
    const rci0_t = RCI0 * @exp(ZETACI * ln_rt);

    // -- Vlim/Vces/Vdck (Eq 2-190 to 2-192) --
    const a_vs = ALVS * t_nom_k;
    const vlim_t = VLIM * @exp((ZETACI - a_vs) * ln_rt);
    const vces_t = VCES * (1.0 + ALCES * delta_t);
    const vdck_t = if (VDCK > 0.0) VDCK * (1.0 - ALDCK * delta_t) else 0.0;

    // -- Transit times (Eq 2-193, 2-194) --
    const t0_t = T0 * (1.0 + ALT0 * delta_t + KT0 * delta_t * delta_t);
    const thcs_t = THCS * @exp((ZETACI - 1.0) * ln_rt);
    const tef0_t = TEF0;

    // -- Avalanche (Eq 2-207) --
    const favl_t = FAVL * @exp(ALFAV * delta_t);
    const qavl_t = QAVL * @exp(ALQAV * delta_t);

    // -- Weight factors (Eq 2-173 to 2-175) --
    const hf0_t = HF0 * @exp(DVGBE / vt * (r_t - 1.0));
    const hjei0_t = HJEI0 * @exp(DVGBE / vt * (@exp(ZETAVGBE * ln_rt) - 1.0));
    const ahjei_t = AHJEI * @exp(ZETAHJEI * ln_rt);

    // -- Tunnelling (Eq 2-209 to 2-215) --
    const vg_be_t0 = (VGB + VGE) / 2.0;
    const vg_be_t = vg_be_t0;
    const ibets_t = if (IBETS > 0.0) IBETS * (vg_be_t0 / vg_be_t) * (vdei_t / VDEI) * (vdei_t / VDEI) * (cjei0_t / CJEI0) else 0.0;
    const abet_t = if (IBETS > 0.0) ABET * @exp(1.5 * @log(@max(vg_be_t / vg_be_t0, 1.0e-30))) * (VDEI / vdei_t) * (CJEI0 / cjei0_t) else ABET;
    const ibetat0_t = if (IBETAT0 > 0.0) IBETAT0 * @exp((VDEI - vdei_t) / VBETAT) else 0.0;

    const vg_bc_t0 = (VGB + VGC) / 2.0;
    const vg_bc_t = vg_bc_t0;
    const ibcts_t = if (IBCTS > 0.0) IBCTS * (vg_bc_t0 / vg_bc_t) * (vdci_t / VDCI) * (vdci_t / VDCI) * (cjci0_t / CJCI0) else 0.0;
    const abct_t = if (IBCTS > 0.0) ABCT * @exp(1.5 * @log(@max(vg_bc_t / vg_bc_t0, 1.0e-30))) * (VDCI / vdci_t) * (CJCI0 / cjci0_t) else ABCT;

    // -- Thermal / substrate resistance (Eq 2-218) --
    const rth_t = if (RTH > 0.0) RTH * (1.0 + ALRTH * delta_t) * @exp(ZETARTH * ln_rt) else 0.0;
    const rsu_t = RSU;

    return .{
        .vt_nom = vt_nom,
        .vt = vt,
        .r_t = r_t,
        .ln_rt = ln_rt,
        .delta_t = delta_t,
        .vdei_t = vdei_t,
        .vdci_t = vdci_t,
        .cjei0_t = cjei0_t,
        .cjci0_t = cjci0_t,
        .ajei_t = ajei_t,
        .ajci_t = ajci_t,
        .c10_t = c10_t,
        .qp0_t = qp0_t,
        .ibeis_t = ibeis_t,
        .ireis_t = ireis_t,
        .ibeps_t = ibeps_t,
        .ireps_t = ireps_t,
        .ibcis_t = ibcis_t,
        .ibcxs_t = ibcxs_t,
        .itss_t = itss_t,
        .iscs_t = iscs_t,
        .rbi0_t = rbi0_t,
        .rbx_t = rbx_t,
        .rcx_t = rcx_t,
        .re_t = re_t,
        .rci0_t = rci0_t,
        .rth_t = rth_t,
        .rsu_t = rsu_t,
        .vlim_t = vlim_t,
        .vces_t = vces_t,
        .vdck_t = vdck_t,
        .t0_t = t0_t,
        .thcs_t = thcs_t,
        .tef0_t = tef0_t,
        .favl_t = favl_t,
        .qavl_t = qavl_t,
        .hf0_t = hf0_t,
        .hjei0_t = hjei0_t,
        .ahjei_t = ahjei_t,
        .ibets_t = ibets_t,
        .abet_t = abet_t,
        .ibetat0_t = ibetat0_t,
        .ibcts_t = ibcts_t,
        .abct_t = abct_t,
    };
}

// ============================================================================
// DC Current Function (value-form) -- quasi-static transfer current
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = t;

    // --- Node indices ---
    const c_n = @intFromEnum(U.c);
    const b_n = @intFromEnum(U.b);
    const e_n = @intFromEnum(U.e);
    const s_n = @intFromEnum(U.s);
    const tn = @intFromEnum(U.tnode);
    const ci_n = @intFromEnum(U.ci);
    const bi_n = @intFromEnum(U.bi);
    const bx_n = @intFromEnum(U.bx);
    const ei_n = @intFromEnum(U.ei);
    const si_n = @intFromEnum(U.si);
    const xf_n = @intFromEnum(U.xf);
    const xf1_n = @intFromEnum(U.xf1);
    const xf2_n = @intFromEnum(U.xf2);

    // --- Type factor (NPN=+1, PNP=-1) ---
    const type_f: f64 = @floatFromInt(model.type_);

    // --- x-independent model scalars needed in the S tail ---
    const HFC: f64 = @as(f64, model.hfc);
    const HJCI: f64 = @as(f64, model.hjci);
    const MCF: f64 = @as(f64, model.mcf);
    const MBEI: f64 = @as(f64, model.mbei);
    const MREI: f64 = @as(f64, model.mrei);
    const MBEP: f64 = @as(f64, model.mbep);
    const MREP: f64 = @as(f64, model.mrep);
    const MBCI: f64 = @as(f64, model.mbci);
    const MBCX: f64 = @as(f64, model.mbcx);
    const TBHREC: f64 = @as(f64, model.tbhrec);
    const VBETAT: f64 = @as(f64, model.vbetat);
    const FAVL_p: f64 = @as(f64, model.favl);
    const KAVL: f64 = @as(f64, model.kavl);
    const HCAVL: f64 = @as(f64, model.hcavl);
    const HVDAVL: f64 = @as(f64, model.hvdavl);
    const RBI0_p: f64 = @as(f64, model.rbi0);
    const FGEO: f64 = @as(f64, model.fgeo);
    const FDQR0: f64 = @as(f64, model.fdqr0);
    const RBX_p: f64 = @as(f64, model.rbx);
    const RCX_p: f64 = @as(f64, model.rcx);
    const RE_p: f64 = @as(f64, model.re);
    const RSU_p: f64 = @as(f64, model.rsu);
    const ITSS_p: f64 = @as(f64, model.itss);
    const MSF: f64 = @as(f64, model.msf);
    const ISCS_p: f64 = @as(f64, model.iscs);
    const MSC: f64 = @as(f64, model.msc);
    const ZEI: f64 = @as(f64, model.zei);
    const VDCI: f64 = @as(f64, model.vdci);
    const ZCI: f64 = @as(f64, model.zci);
    const VPTCI: f64 = @as(f64, model.vptci);
    const DT0H: f64 = @as(f64, model.dt0h);
    const TBVL: f64 = @as(f64, model.tbvl);
    const GTFE: f64 = @as(f64, model.gtfe);
    const AHC: f64 = @as(f64, model.ahc);
    const FTHC: f64 = @as(f64, model.fthc);
    const VLIM: f64 = @as(f64, model.vlim);
    const VCES: f64 = @as(f64, model.vces);
    const VDCK: f64 = @as(f64, model.vdck);
    const VPT: f64 = @as(f64, model.vpt);
    const DELCK: f64 = @as(f64, model.delck);
    const AICK: f64 = @as(f64, model.aick);
    const TR: f64 = @as(f64, model.tr);
    const VCBAR: f64 = @as(f64, model.vcbar);
    const ICBAR: f64 = @as(f64, model.icbar);
    const ACBAR: f64 = @as(f64, model.acbar);
    const AVCSM: f64 = @as(f64, model.avcsm);
    const LATB: f64 = @as(f64, model.latb);
    const LATL: f64 = @as(f64, model.latl);
    const RHJEI: f64 = @as(f64, model.rhjei);
    _ = HFC;
    _ = VCES;
    _ = VLIM;

    const FLSH: i32 = model.flsh;
    const FLCOMP: i32 = model.flcomp;
    const TUNODE: i32 = model.tunode;
    const FLNQS: i32 = model.flnqs;
    const RTH_p: f64 = @as(f64, model.rth);

    const m_mult: f64 = @as(f64, instance.m);

    // ------------------------------------------------------------------
    // Self-heating delta-T: read x[tnode] as f64 (see concerns).
    // ------------------------------------------------------------------
    const dt_sh: f64 = if (FLSH > 0 and RTH_p > 0.0) x[tn].val() else 0.0;
    const P = tempParams(model, instance, dt_sh);
    const vt = P.vt;
    const vt_nom = P.vt_nom;

    // Derived f64 constants used inside S chains
    const vdei_t = P.vdei_t;
    const vdci_t = P.vdci_t;
    const cjei0_t = P.cjei0_t;
    const cjci0_t = P.cjci0_t;
    const ajei_t = P.ajei_t;
    const ajci_t = P.ajci_t;
    const rci0_safe = @max(P.rci0_t, 1.0e-30);

    // ========================================================================
    // Branch voltages (with type factor) -- S chains from here on
    // ========================================================================
    const v_biei = x[bi_n].sub(x[ei_n]).scale(type_f);
    const v_bici = x[bi_n].sub(x[ci_n]).scale(type_f);
    const v_bxei = x[bx_n].sub(x[ei_n]).scale(type_f);
    const v_bxci = x[bx_n].sub(x[ci_n]).scale(type_f);
    const v_bxbi = x[bx_n].sub(x[bi_n]).scale(type_f);
    const v_ciei = x[ci_n].sub(x[ei_n]).scale(type_f);
    const v_sici = x[si_n].sub(x[ci_n]).scale(type_f);
    const v_bc_ext = x[b_n].sub(x[bx_n]).scale(type_f);
    const v_ce_ext = x[c_n].sub(x[ci_n]).scale(type_f);
    const v_ee_ext = x[e_n].sub(x[ei_n]).scale(type_f);
    const v_ss_ext = x[s_n].sub(x[si_n]).scale(type_f);

    // ========================================================================
    // Internal BE Depletion Charge (Eq 2-70 to 2-76)
    // ========================================================================
    const vf_ei = vdei_t * (1.0 - @exp((-1.0 / ZEI) * @log(@max(ajei_t, 1.0e-30))));
    // x_ei = (vf_ei - v_biei)/vt
    const x_ei = v_biei.neg().addC(vf_ei).scale(1.0 / vt);
    // vj_ei = vf_ei - vt*(x_ei + sqrt(x_ei^2 + a_fj))/2
    const vj_ei = x_ei.add(x_ei.mul(x_ei).addC(a_fj).sqrt()).scale(vt / 2.0).neg().addC(vf_ei);

    // qjei
    const one_m_vjei = vj_ei.scale(-1.0 / vdei_t).addC(1.0).maxC(1.0e-30);
    const qjei = one_m_vjei.log().scale(1.0 - ZEI).exp().neg().addC(1.0).scale(cjei0_t * vdei_t / (1.0 - ZEI))
        .add(v_biei.sub(vj_ei).scale(ajei_t * cjei0_t));

    // normalized capacitance
    const cjei_norm = one_m_vjei.log().scale(-ZEI).exp();

    // ========================================================================
    // Internal BC Depletion Charge (with punch-through, Eq 2-77 to 2-90)
    // ========================================================================
    const vptci_eff = VPTCI - VDCI;
    const vptci_t_eff = vptci_eff;
    const vfci = vdci_t * (1.0 - @exp((-1.0 / ZCI) * @log(@max(ajci_t, 1.0e-30))));
    const vr_ci = 0.1 * vptci_t_eff + 4.0 * vt;

    // vjr = vfci - vt*log(1 + exp(min((vfci - v_bici)/vt, 80)))
    const ejr = v_bici.neg().addC(vfci).scale(1.0 / vt).minC(80.0).exp();
    const vjr = ejr.addC(1.0).maxC(1.0e-30).log().scale(vt).neg().addC(vfci);

    // vjm = -vptci + vr_ci*log(1 + exp(min((vptci + vjr)/vr_ci, 80))) - exp(min(-(vptci+vfci)/vr_ci,80))
    const ejm = vjr.addC(vptci_t_eff).scale(1.0 / vr_ci).minC(80.0).exp();
    const vjm_const = -@as(f64, @exp(@min(-(vptci_t_eff + vfci) / vr_ci, 80.0)));
    const vjm = ejm.addC(1.0).maxC(1.0e-30).log().scale(vr_ci).addC(-vptci_t_eff + vjm_const);

    const zcir = ZCI / 4.0;
    const cjci0r = cjci0_t * @exp((ZCI - zcir) * @log(@max(vdci_t / (vptci_eff + VDCI), 1.0e-30)));

    const one_m_vjm = vjm.scale(-1.0 / vdci_t).addC(1.0).maxC(1.0e-30);
    const one_m_vjr = vjr.scale(-1.0 / vdci_t).addC(1.0).maxC(1.0e-30);

    const qjci_m = one_m_vjm.log().scale(1.0 - ZCI).exp().neg().addC(1.0).scale(cjci0_t * vdci_t / (1.0 - ZCI));
    const qjci_r = one_m_vjr.log().scale(1.0 - zcir).exp().neg().addC(1.0).scale(cjci0r * vdci_t / (1.0 - zcir));
    const qjci_c = one_m_vjm.log().scale(1.0 - zcir).exp().neg().addC(1.0).scale(cjci0r * vdci_t / (1.0 - zcir));
    const qjci = qjci_m.add(qjci_r).sub(qjci_c).add(v_bici.sub(vjr).scale(ajci_t * cjci0_t));

    const cjci_cap = one_m_vjm.log().scale(-ZCI).exp();
    const cjci_cap_inf_pt = one_m_vjr.log().scale(-ZCI).exp();

    // ========================================================================
    // HBT Weight Factor h_jEi (Eq 2-13 to 2-18)
    // ========================================================================
    const hjei_val: S = blk: {
        if (P.ahjei_t > 0.0) {
            const rvt = @max(RHJEI, 0.01) * vt;
            // xu = (vdei_t - v_biei)/rvt
            const xu = v_biei.neg().addC(vdei_t).scale(1.0 / rvt);
            // vju = vdei_t - rvt*(xu + sqrt(xu^2 + a_fj))/2
            const vju = xu.add(xu.mul(xu).addC(a_fj).sqrt()).scale(rvt / 2.0).neg().addC(vdei_t);
            // u = ahjei_t*(1 - (1 - vju/vdei_t)^ZEI)
            const u = vju.scale(-1.0 / vdei_t).addC(1.0).maxC(1.0e-30).log().scale(ZEI).exp().neg().addC(1.0).scale(P.ahjei_t);
            // Bernoulli B(u): branch on |u| (region selection, matches original)
            const u_min: f64 = 0.001;
            if (@abs(u.val()) >= u_min) {
                const bu = u.minC(80.0).exp().addC(-1.0).div(u);
                break :blk bu.scale(P.hjei0_t);
            } else {
                const bu = u.scale(0.5).addC(1.0);
                break :blk bu.scale(P.hjei0_t);
            }
        } else {
            break :blk S.con(P.hjei0_t);
        }
    };

    // ========================================================================
    // GICCR: Transfer Current (Eq 2-1 to 2-24)
    // ========================================================================
    const exp_bf = v_biei.scale(1.0 / (MCF * vt)).minC(80.0).exp();
    const exp_br = v_bici.scale(1.0 / vt).minC(80.0).exp();

    // qpt_j = qp0_t + hjei*qjei + HJCI*qjci
    const qpt_j = hjei_val.mul(qjei).add(qjci.scale(HJCI)).addC(P.qp0_t);

    const qb_rt = 0.05 * P.qp0_t;
    // x_qp = qpt_j/qb_rt - 1
    const x_qp = qpt_j.scale(1.0 / qb_rt).addC(-1.0);
    // qpt_low = qb_rt*(1 + (x_qp + sqrt(x_qp^2 + a_fj))/2)
    const qpt_low = x_qp.add(x_qp.mul(x_qp).addC(a_fj).sqrt()).scale(0.5).addC(1.0).scale(qb_rt);

    const qpt_half = qpt_low.scale(0.5);
    // qpt_sq = qpt_half^2 + hf0*t0*c10*exp_bf + TR*c10*exp_br
    const qpt_sq = qpt_half.mul(qpt_half)
        .add(exp_bf.scale(P.hf0_t * P.t0_t * P.c10_t))
        .add(exp_br.scale(TR * P.c10_t));
    const qpt = qpt_half.add(qpt_sq.maxC(1.0e-30).sqrt());

    const qpt_safe = qpt.maxC(1.0e-30);
    const itf = exp_bf.scale(P.c10_t).div(qpt_safe);
    const itr = exp_br.scale(P.c10_t).div(qpt_safe);
    const it_val = itf.sub(itr).scale(m_mult);

    // ========================================================================
    // Effective Collector Voltage (Eq 2-29 to 2-33)
    // ========================================================================
    const vceff: S = blk: {
        if (VDCK > 0.0 and FLCOMP >= 310) {
            // vc = vdck_t - v_bici; u_vc = vc/vt_nom; vceff = vt_nom*(u_vc+sqrt(u_vc^2+AVCSM))/2
            const u_vc = v_bici.neg().addC(P.vdck_t).scale(1.0 / vt_nom);
            break :blk u_vc.add(u_vc.mul(u_vc).addC(AVCSM).sqrt()).scale(vt_nom / 2.0);
        } else {
            // vc = v_ciei - vces_t; u_vc = (vc - vt)/vt; vceff = vt*(1 + (u_vc+sqrt(u_vc^2+a_fj))/2)
            const u_vc = v_ciei.addC(-P.vces_t - vt).scale(1.0 / vt);
            break :blk u_vc.add(u_vc.mul(u_vc).addC(a_fj).sqrt()).scale(0.5).addC(1.0).scale(vt);
        }
    };

    // ========================================================================
    // Critical Current I_CK (Eq 2-36)
    // ========================================================================
    const vlim_safe = @max(P.vlim_t, 1.0e-30);
    // v_ratio = vceff/vlim_safe
    const v_ratio = vceff.scale(1.0 / vlim_safe);
    // v_ratio_dck = v_ratio^DELCK  (via log/exp with clamp)
    const v_ratio_dck = v_ratio.maxC(1.0e-30).log().scale(DELCK).exp();
    // denom_ick = (1 + v_ratio_dck)^(1/DELCK)
    const denom_ick = v_ratio_dck.addC(1.0).maxC(1.0e-30).log().scale(1.0 / DELCK).exp();

    const vpt_eff: f64 = if (VPT > 0.0) VPT else 1.0e30;
    // x_pt = (vceff - vlim_t)/vpt_eff
    const x_pt = vceff.addC(-P.vlim_t).scale(1.0 / vpt_eff);
    // pt_factor = 1 + (x_pt + sqrt(x_pt^2 + AICK))/2
    const pt_factor = x_pt.add(x_pt.mul(x_pt).addC(AICK).sqrt()).scale(0.5).addC(1.0);

    // ick = vceff/rci0_safe/denom_ick * pt_factor
    const ick = vceff.scale(1.0 / rci0_safe).div(denom_ick.maxC(1.0e-30)).mul(pt_factor);

    // ========================================================================
    // Low-Current Transit Time tau_f0 (Eq 2-34)
    // ========================================================================
    const inv_c_ci = cjci_cap_inf_pt; // S
    // c_ci_ratio = 1/inv_c_ci (guard as original: if inv>1e-30 else 1e30)
    const c_ci_ratio = if (inv_c_ci.val() > 1.0e-30) inv_c_ci.pow(-1.0) else S.con(1.0e30);
    // tau_f0 = t0_t + DT0H*(inv_c_ci - 1) + TBVL*(c_ci_ratio - 1)
    const tau_f0 = inv_c_ci.addC(-1.0).scale(DT0H)
        .add(c_ci_ratio.addC(-1.0).scale(TBVL))
        .addC(P.t0_t);

    // ========================================================================
    // High Current Effects: Injection Width w (Eq 2-45, 2-46)
    // ========================================================================
    const itf_safe = itf.maxC(1.0e-30);
    const ick_safe = ick.maxC(1.0e-30);
    // i_ratio = 1 - ick_safe/itf_safe
    const i_ratio = ick_safe.div(itf_safe).neg().addC(1.0);
    const sqrt_1_ahc = @sqrt(1.0 + AHC);
    // w_norm_raw = (i_ratio + sqrt(i_ratio^2 + AHC))/(1 + sqrt(1+AHC))
    const w_norm_raw = i_ratio.add(i_ratio.mul(i_ratio).addC(AHC).sqrt()).scale(1.0 / (1.0 + sqrt_1_ahc));
    const w_norm = w_norm_raw.minC(1.0).maxC(0.0);

    // ========================================================================
    // Emitter Transit Time Increase (Eq 2-40, 2-42)
    // ========================================================================
    const dq_ef: S = if (P.tef0_t > 0.0) blk: {
        // dtef = tef0*(itf/ick_safe)^GTFE
        const dtef = itf.div(ick_safe).maxC(1.0e-30).log().scale(GTFE).exp().scale(P.tef0_t);
        break :blk dtef.mul(itf).scale(1.0 / (1.0 + GTFE));
    } else S.con(0.0);

    // ========================================================================
    // Base+Collector High-Current Charge (Eq 2-53)
    // ========================================================================
    const dq_fh = itf.mul(w_norm).mul(w_norm).scale(P.thcs_t);

    // ========================================================================
    // BC Barrier Effect (Eq 2-57 to 2-66)
    // ========================================================================
    const dq_fh_final: S = blk: {
        if (VCBAR > 0.0 and ICBAR > 0.0) {
            // ibar = (itf - ick)/ICBAR
            const ibar = itf.sub(ick).scale(1.0 / @max(ICBAR, 1.0e-30));
            // dvcb = VCBAR*exp(-2/(ibar + sqrt(ibar^2 + ACBAR)))
            const dvcb = ibar.add(ibar.mul(ibar).addC(ACBAR).sqrt()).pow(-1.0).scale(-2.0).exp().scale(VCBAR);
            // dq_fhc = dq_fh*exp(min((dvcb-VCBAR)/vt, 80))
            const dq_fhc = dq_fh.mul(dvcb.addC(-VCBAR).scale(1.0 / vt).minC(80.0).exp());
            const tau_bfvs = (1.0 - FTHC) * P.thcs_t;
            // dq_bfb = tau_bfvs*itf*(exp(min(dvcb/vt,80)) - 1)
            const dq_bfb = dvcb.scale(1.0 / vt).minC(80.0).exp().addC(-1.0).mul(itf).scale(tau_bfvs);
            break :blk dq_fhc.add(dq_bfb);
        } else {
            break :blk dq_fh;
        }
    };

    // ========================================================================
    // Lateral Current Spreading (Eq 2-221 to 2-230)
    // ========================================================================
    const w_norm_lat: S = blk: {
        if (LATB > 0.0) {
            const zeta_b = LATB;
            const zeta_l = LATL;
            // i_ck_2d = clamp(1 - (i_ratio + sqrt(i_ratio^2+AHC))/(1+sqrt(1+AHC)), 0, 1)
            const i_ck_2d = i_ratio.add(i_ratio.mul(i_ratio).addC(AHC).sqrt()).scale(1.0 / (1.0 + sqrt_1_ahc)).neg().addC(1.0).minC(1.0).maxC(0.0);

            if (zeta_l > 0.0 and zeta_b != zeta_l) {
                // kappa = ((1+zeta_b)/(1+zeta_l))^(i_ck_2d - 1)  [variable exponent]
                const base_k = @max((1.0 + zeta_b) / (1.0 + zeta_l), 1.0e-30);
                const kappa = i_ck_2d.addC(-1.0).scale(@log(base_k)).exp();
                // w_lat = (kappa - 1)/(zeta_l - kappa*zeta_b)
                const w_lat = kappa.addC(-1.0).div(kappa.scale(-zeta_b).addC(zeta_l).maxC(1.0e-30));
                break :blk w_lat.minC(1.0).maxC(0.0);
            } else if (zeta_l == 0.0) {
                // w_lat = (1/(1 + i_ck_2d*zeta_b)*(1+zeta_b) - 1)/zeta_b
                const w_lat = i_ck_2d.scale(zeta_b).addC(1.0).pow(-1.0).scale(1.0 + zeta_b).addC(-1.0).scale(1.0 / @max(zeta_b, 1.0e-30));
                break :blk w_lat.minC(1.0).maxC(0.0);
            } else {
                // w_lat = ((1+zeta_b)/(1 + i_ck_2d*zeta_b) - 1)/zeta_b
                const w_lat = i_ck_2d.scale(zeta_b).addC(1.0).pow(-1.0).scale(1.0 + zeta_b).addC(-1.0).scale(1.0 / @max(zeta_b, 1.0e-30));
                break :blk w_lat.minC(1.0).maxC(0.0);
            }
        } else {
            break :blk w_norm;
        }
    };

    // ========================================================================
    // Total Minority Charge and Forward Transit Time (Eq 2-55, 2-56)
    // ========================================================================
    const dq_fh_lat: S = if (LATB > 0.0) itf.mul(w_norm_lat).mul(w_norm_lat).scale(P.thcs_t) else dq_fh_final;
    const qf = tau_f0.mul(itf).add(dq_ef).add(dq_fh_lat);

    // ========================================================================
    // Base-Emitter Junction Currents (Eq 2-93)
    // ========================================================================
    const ijbei = v_biei.scale(1.0 / (MBEI * vt)).minC(80.0).exp().addC(-1.0).scale(P.ibeis_t)
        .add(v_biei.scale(1.0 / (MREI * vt)).minC(80.0).exp().addC(-1.0).scale(P.ireis_t))
        .add(v_biei.scale(gmin));

    const ijbep = v_bxei.scale(1.0 / (MBEP * vt)).minC(80.0).exp().addC(-1.0).scale(P.ibeps_t)
        .add(v_bxei.scale(1.0 / (MREP * vt)).minC(80.0).exp().addC(-1.0).scale(P.ireps_t))
        .add(v_bxei.scale(gmin));

    // ========================================================================
    // BE Tunnelling Currents (Eq 2-101, 2-104)
    // ========================================================================
    const ibeti: S = blk: {
        if (P.ibets_t > 0.0) {
            // ve_tun = 1 - cjei_norm^(-1/ZEI)
            const ve_tun = cjei_norm.maxC(1.0e-30).log().scale(-1.0 / ZEI).exp().neg().addC(1.0);
            // ce_inv = cjei_norm^(1/ZEI - 1)
            const ce_inv = cjei_norm.maxC(1.0e-30).log().scale(1.0 / ZEI - 1.0).exp();
            // ibets*max(-ve_tun,0)*cjei_norm^(1-1/ZEI)*exp(min(-abet*ce_inv,80))
            const term_pow = cjei_norm.maxC(1.0e-30).log().scale(1.0 - 1.0 / ZEI).exp();
            const term_exp = ce_inv.scale(-P.abet_t).minC(80.0).exp();
            break :blk ve_tun.neg().maxC(0.0).mul(term_pow).mul(term_exp).scale(P.ibets_t);
        } else {
            break :blk S.con(0.0);
        }
    };

    const ibetat: S = if (P.ibetat0_t > 0.0)
        v_biei.scale(1.0 / VBETAT).minC(80.0).exp().addC(-1.0).scale(P.ibetat0_t)
    else
        S.con(0.0);

    const ibe_tun_i = ibeti.add(ibetat);

    // ========================================================================
    // BC Junction Currents (Eq 2-106, 2-107)
    // ========================================================================
    const ijbci = v_bici.scale(1.0 / (MBCI * vt)).minC(80.0).exp().addC(-1.0).scale(P.ibcis_t)
        .add(v_bici.scale(gmin));
    const ijbcx = v_bxci.scale(1.0 / (MBCX * vt)).minC(80.0).exp().addC(-1.0).scale(P.ibcxs_t)
        .add(v_bxci.scale(gmin));

    // ========================================================================
    // BC BtBT Current (Eq 2-118)
    // ========================================================================
    const ibct: S = blk: {
        if (P.ibcts_t > 0.0) {
            const cc_norm = cjci_cap;
            const vc_tun = cc_norm.maxC(1.0e-30).log().scale(-1.0 / ZCI).exp().neg().addC(1.0);
            const cc_inv = cc_norm.maxC(1.0e-30).log().scale(1.0 / ZCI - 1.0).exp();
            const term_pow = cc_norm.maxC(1.0e-30).log().scale(1.0 - 1.0 / ZCI).exp();
            const term_exp = cc_inv.scale(-P.abct_t).minC(80.0).exp();
            break :blk vc_tun.neg().maxC(0.0).mul(term_pow).mul(term_exp).scale(P.ibcts_t);
        } else {
            break :blk S.con(0.0);
        }
    };

    // ========================================================================
    // BC Barrier Recombination Current (Eq 2-108)
    // ========================================================================
    const dq_bf: S = blk: {
        if (VCBAR > 0.0 and ICBAR > 0.0) {
            const ibar = itf.sub(ick).scale(1.0 / @max(ICBAR, 1.0e-30));
            const dvcb = ibar.add(ibar.mul(ibar).addC(ACBAR).sqrt()).pow(-1.0).scale(-2.0).exp().scale(VCBAR);
            const tau_bfvs = (1.0 - FTHC) * P.thcs_t;
            const dq_bfb = dvcb.scale(1.0 / vt).minC(80.0).exp().addC(-1.0).mul(itf).scale(tau_bfvs);
            const dq_fhc_val = dq_fh.mul(dvcb.addC(-VCBAR).scale(1.0 / vt).minC(80.0).exp());
            const dq_bfc = dq_fhc_val.scale(1.0 - FTHC);
            break :blk dq_bfb.add(dq_bfc);
        } else {
            break :blk dq_fh.scale(1.0 - FTHC);
        }
    };

    const ibhrec: S = if (TBHREC > 0.0) dq_bf.scale(1.0 / TBHREC) else S.con(0.0);

    // ========================================================================
    // Avalanche Current (Eq 2-110 to 2-117)
    // ========================================================================
    // Region select on v_bici < vdci_t (original branched on the voltage).
    const iavl: S = blk: {
        if (P.favl_t > 0.0 and v_bici.val() < vdci_t) {
            // vdci_m_vbc = vdci_t - v_bici
            const vdci_m_vbc = v_bici.neg().addC(vdci_t);
            const cjci_avl = cjci_cap.scale(cjci0_t); // C_jCi(V_B'C')

            // gavl_base = favl*vdci_m_vbc*exp(min(-qavl/(max(cjci_avl,1e-30)*vdci_m_vbc), 80))
            const gavl_base = vdci_m_vbc.mul(cjci_avl.maxC(1.0e-30).mul(vdci_m_vbc).pow(-1.0).scale(-P.qavl_t).minC(80.0).exp()).scale(P.favl_t);

            const gavl: S = blk2: {
                if (HCAVL > 0.0) {
                    const ilim_val = P.vlim_t / rci0_safe;
                    // ilim_avl = HCAVL*ilim_val + HVDAVL*itf
                    const ilim_avl = itf.scale(HVDAVL).addC(HCAVL * ilim_val);
                    const s_mavl: f64 = 0.1;
                    const c_mavl: f64 = 1.0;
                    // cjci_ratio_avl = cjci_avl/cjci0_t
                    const cjci_ratio_avl = cjci_avl.scale(1.0 / @max(cjci0_t, 1.0e-30));
                    // itf_ilim = 1 - itf/ilim_avl
                    const itf_ilim = itf.div(ilim_avl.maxC(1.0e-30)).neg().addC(1.0);
                    // cosh_val = (exp(min(cosh_arg,40)) + exp(min(-cosh_arg,40)))/2
                    const cosh_arg = itf_ilim.scale(1.0 / s_mavl);
                    const cosh_val = cosh_arg.minC(40.0).exp().add(cosh_arg.neg().minC(40.0).exp()).scale(0.5);
                    // log_arg = max(exp(min(c_mavl*cjci_ratio_avl/s_mavl,80)) - 2 + 2*cosh_val, 1e-30)
                    const log_arg = cjci_ratio_avl.scale(c_mavl / s_mavl).minC(80.0).exp().add(cosh_val.scale(2.0)).addC(-2.0).maxC(1.0e-30);
                    // favi = sqrt(s_mavl*log(log_arg))
                    const favi = log_arg.log().scale(s_mavl).maxC(0.0).sqrt();
                    break :blk2 vdci_m_vbc.mul(cjci_avl.mul(favi).maxC(1.0e-30).mul(vdci_m_vbc).pow(-1.0).scale(-P.qavl_t).minC(80.0).exp()).scale(P.favl_t);
                } else {
                    break :blk2 gavl_base;
                }
            };

            const denom_avl: S = if (KAVL > 0.0) blk3: {
                // raw = 1 - KAVL*gavl; (raw + sqrt(raw^2+1e-4))/2
                const raw = gavl.scale(-KAVL).addC(1.0);
                break :blk3 raw.add(raw.mul(raw).addC(1.0e-4).sqrt()).scale(0.5);
            } else S.con(1.0);

            break :blk itf.mul(gavl).div(denom_avl.maxC(1.0e-30));
        } else {
            break :blk S.con(0.0);
        }
    };

    // ========================================================================
    // Internal Base Resistance r_Bi (Eq 2-124 to 2-134)
    // ========================================================================
    const rbi_val: S = blk: {
        if (P.rbi0_t > 0.0) {
            const q0_mod = (1.0 + FDQR0) * P.qp0_t;
            const dqp = qjei.add(qjci).add(qf);
            // qr_mod = 1 + dqp/q0_mod
            const qr_mod = dqp.scale(1.0 / @max(q0_mod, 1.0e-30)).addC(1.0);
            const a_qr: f64 = 0.01;
            // fqr = (qr_mod + sqrt(qr_mod^2 + a_qr))/2
            const fqr = qr_mod.add(qr_mod.mul(qr_mod).addC(a_qr).sqrt()).scale(0.5);
            // ri = rbi0/fqr
            const ri = fqr.maxC(1.0e-30).pow(-1.0).scale(P.rbi0_t);
            // eta = FGEO*ri*|ijbei|/vt
            const eta = ri.mul(ijbei.abs()).scale(FGEO / vt);
            // psi = ln(1+eta)/eta if eta>1e-6 else 1 - eta/2 (region select on eta)
            if (eta.val() > 1.0e-6) {
                const psi = eta.addC(1.0).log().div(eta);
                break :blk ri.mul(psi);
            } else {
                const psi = eta.scale(-0.5).addC(1.0);
                break :blk ri.mul(psi);
            }
        } else {
            break :blk S.con(0.0);
        }
    };

    // ========================================================================
    // Substrate Transistor (Eq 2-151, 2-152)
    // ========================================================================
    const its: S = if (ITSS_p > 0.0 or P.itss_t > 0.0)
        v_bxci.scale(1.0 / (MSF * vt)).minC(80.0).exp().sub(v_sici.scale(1.0 / (MSF * vt)).minC(80.0).exp()).scale(P.itss_t)
    else
        S.con(0.0);

    const ijsc: S = if (ISCS_p > 0.0)
        v_sici.scale(1.0 / (MSC * vt)).minC(80.0).exp().addC(-1.0).scale(P.iscs_t).add(v_sici.scale(gmin))
    else
        v_sici.scale(gmin);

    // ========================================================================
    // Series Resistance Conductances (GSHORT for zero resistance)
    // ========================================================================
    const GSHORT: f64 = 1.0e12;
    const g_rbx = if (P.rbx_t > 0.0) m_mult / P.rbx_t else GSHORT;
    const g_rcx = if (P.rcx_t > 0.0) m_mult / P.rcx_t else GSHORT;
    const g_re = if (P.re_t > 0.0) m_mult / P.re_t else GSHORT;
    const g_rsu = if (P.rsu_t > 0.0) m_mult / P.rsu_t else GSHORT;
    const g_rth = if (P.rth_t > 0.0) 1.0 / P.rth_t else GSHORT;

    // Internal base resistance (bias-dependent): g_rbi = m/rbi_val if rbi_val>0 else GSHORT
    const rbi_pos = P.rbi0_t > 0.0 and rbi_val.val() > 0.0;
    const g_rbi: S = if (rbi_pos) rbi_val.pow(-1.0).scale(m_mult) else S.con(GSHORT);

    _ = RBI0_p;
    _ = RBX_p;
    _ = RCX_p;
    _ = RE_p;
    _ = RSU_p;
    _ = FAVL_p;

    // ========================================================================
    // Self-Heating Power (Eq 2-219, 2-220)
    // ========================================================================
    const p_dissip: S = blk: {
        if (FLSH >= 1 and RTH_p > 0.0) {
            // p = it*v_ciei + iavl*m*(vdci_t - v_bici)
            var p = it_val.mul(v_ciei).add(iavl.scale(m_mult).mul(v_bici.neg().addC(vdci_t)));
            if (FLSH >= 2) {
                p = p.add(ijbei.scale(m_mult).mul(v_biei));
                p = p.add(ijbci.scale(m_mult).mul(v_bici));
                p = p.add(ijbep.scale(m_mult).mul(v_bxei));
                p = p.add(ijbcx.scale(m_mult).mul(v_bxci));
                p = p.add(ijsc.scale(m_mult).mul(v_sici));
                if (rbi_pos) p = p.add(v_bxbi.mul(v_bxbi).mul(g_rbi));
                if (P.rbx_t > 0.0) p = p.add(v_bc_ext.mul(v_bc_ext).scale(g_rbx));
                if (P.re_t > 0.0) p = p.add(v_ee_ext.mul(v_ee_ext).scale(g_re));
                if (P.rcx_t > 0.0) p = p.add(v_ce_ext.mul(v_ce_ext).scale(g_rcx));
            }
            break :blk p;
        } else {
            break :blk S.con(0.0);
        }
    };

    // ========================================================================
    // KCL Current Contributions (scaled by multiplier)
    // ========================================================================
    const ijbei_m = ijbei.scale(m_mult);
    const ijbep_m = ijbep.scale(m_mult);
    const ijbci_m = ijbci.scale(m_mult);
    const ijbcx_m = ijbcx.scale(m_mult);
    const ibhrec_m = ibhrec.scale(m_mult);
    const iavl_m = iavl.scale(m_mult);
    const its_m = its.scale(m_mult);
    const ijsc_m = ijsc.scale(m_mult);
    const ibct_m = ibct.scale(m_mult);

    const ibe_tun_bi: S = if (TUNODE == 0) ibe_tun_i.scale(m_mult) else S.con(0.0);
    const ibe_tun_bx: S = if (TUNODE == 1) ibe_tun_i.scale(m_mult) else S.con(0.0);

    // Series resistance currents
    const i_rbx = v_bc_ext.scale(g_rbx);
    const i_rbi = v_bxbi.mul(g_rbi);
    const i_rcx = v_ce_ext.scale(g_rcx);
    const i_re = v_ee_ext.scale(g_re);
    const i_rsu = v_ss_ext.scale(g_rsu);

    // Thermal node: out[tnode] = dT/Rth - P_dissip
    const i_th: S = if (RTH_p > 0.0) x[tn].scale(g_rth).sub(p_dissip) else S.con(0.0);

    // NQS node currents (QS mode: shorted to ground)
    const g_nqs: f64 = if (FLNQS == 0) GSHORT else 1.0;
    const i_xf = x[xf_n].scale(g_nqs);
    const i_xf1 = x[xf1_n].scale(g_nqs);
    const i_xf2 = x[xf2_n].scale(g_nqs);

    // ========================================================================
    // Assemble output KCL -- each node's current equation
    // ========================================================================
    var out: [n_u]S = undefined;

    // External collector (c): i_rcx out
    out[c_n] = i_rcx.scale(type_f);
    // External base (b): i_rbx out
    out[b_n] = i_rbx.scale(type_f);
    // External emitter (e): i_re out
    out[e_n] = i_re.scale(type_f);
    // External substrate (s): i_rsu out
    out[s_n] = i_rsu.scale(type_f);
    // Thermal node
    out[tn] = i_th;
    // Intrinsic collector (ci)
    out[ci_n] = it_val.add(iavl_m).sub(ijbci_m).sub(ibct_m).sub(i_rcx).sub(its_m).sub(ijsc_m).scale(type_f);
    // Intrinsic base (bi)
    out[bi_n] = ijbei_m.add(ijbci_m).add(ibhrec_m).add(ibe_tun_bi).sub(it_val).sub(iavl_m).sub(i_rbi).scale(type_f);
    // Perimeter base (bx)
    out[bx_n] = ijbep_m.add(ijbcx_m).add(ibe_tun_bx).add(i_rbi).sub(i_rbx).add(its_m).scale(type_f);
    // Intrinsic emitter (ei)
    out[ei_n] = ijbei_m.neg().sub(ijbep_m).sub(ibe_tun_bi).sub(ibe_tun_bx).add(it_val).sub(i_re).scale(type_f);
    // Intrinsic substrate (si)
    out[si_n] = ijsc_m.sub(i_rsu).scale(type_f);
    // NQS nodes
    out[xf_n] = i_xf;
    out[xf1_n] = i_xf1;
    out[xf2_n] = i_xf2;

    return out;
}

// ============================================================================
// Charge Function q (value-form) -- Depletion + Diffusion + Parasitic Charges
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = t;

    const ci_n = @intFromEnum(U.ci);
    const bi_n = @intFromEnum(U.bi);
    const bx_n = @intFromEnum(U.bx);
    const ei_n = @intFromEnum(U.ei);
    const si_n = @intFromEnum(U.si);
    const c_n = @intFromEnum(U.c);
    const b_n = @intFromEnum(U.b);
    const e_n = @intFromEnum(U.e);
    const s_n = @intFromEnum(U.s);
    const tn = @intFromEnum(U.tnode);
    const xf_n = @intFromEnum(U.xf);
    const xf1_n = @intFromEnum(U.xf1);
    const xf2_n = @intFromEnum(U.xf2);

    const type_f: f64 = @floatFromInt(model.type_);

    // x-independent model scalars used in the S tail
    const HJCI: f64 = @as(f64, model.hjci);
    const MCF: f64 = @as(f64, model.mcf);
    const ZEI: f64 = @as(f64, model.zei);
    const VDEP: f64 = @as(f64, model.vdep);
    const ZEP: f64 = @as(f64, model.zep);
    const AJEP: f64 = @as(f64, model.ajep);
    const VDCI: f64 = @as(f64, model.vdci);
    const ZCI: f64 = @as(f64, model.zci);
    const VPTCI: f64 = @as(f64, model.vptci);
    const VDCX: f64 = @as(f64, model.vdcx);
    const ZCX: f64 = @as(f64, model.zcx);
    const AJCX: f64 = @as(f64, model.ajcx);
    const VPTCX: f64 = @as(f64, model.vptcx);
    const VDS: f64 = @as(f64, model.vds);
    const ZS: f64 = @as(f64, model.zs);
    const AJS: f64 = @as(f64, model.ajs);
    const VPTS: f64 = @as(f64, model.vpts);
    const VDSP: f64 = @as(f64, model.vdsp);
    const ZSP: f64 = @as(f64, model.zsp);
    const VPTSP: f64 = @as(f64, model.vptsp);
    const DT0H: f64 = @as(f64, model.dt0h);
    const TBVL: f64 = @as(f64, model.tbvl);
    const TEF0: f64 = @as(f64, model.tef0);
    const GTFE: f64 = @as(f64, model.gtfe);
    const AHC: f64 = @as(f64, model.ahc);
    const FTHC: f64 = @as(f64, model.fthc);
    const VDCK: f64 = @as(f64, model.vdck);
    const VPT: f64 = @as(f64, model.vpt);
    const DELCK: f64 = @as(f64, model.delck);
    const AICK: f64 = @as(f64, model.aick);
    const TR: f64 = @as(f64, model.tr);
    const VCBAR: f64 = @as(f64, model.vcbar);
    const ICBAR: f64 = @as(f64, model.icbar);
    const ACBAR: f64 = @as(f64, model.acbar);
    const AVCSM: f64 = @as(f64, model.avcsm);
    const FQI: f64 = @as(f64, model.fqi);
    const FCRBI: f64 = @as(f64, model.fcrbi);
    const CBEPAR: f64 = @as(f64, model.cbepar);
    const FBEPAR: f64 = @as(f64, model.fbepar);
    const CBCPAR: f64 = @as(f64, model.cbcpar);
    const FBCPAR: f64 = @as(f64, model.fbcpar);
    const CCEPAR: f64 = @as(f64, model.ccepar);
    const CSU: f64 = @as(f64, model.csu);
    const MSF: f64 = @as(f64, model.msf);
    const TSF: f64 = @as(f64, model.tsf);
    const CTH: f64 = @as(f64, model.cth);
    const HR0C: f64 = @as(f64, model.hr0c);
    const ALQF: f64 = @as(f64, model.alqf);
    const ALIT: f64 = @as(f64, model.alit);
    const RHJEI: f64 = @as(f64, model.rhjei);
    const ZETACX: f64 = @as(f64, model.zetacx);

    const FLSH: i32 = model.flsh;
    const FLCOMP: i32 = model.flcomp;
    const FLNQS: i32 = model.flnqs;
    const RTH_p: f64 = @as(f64, model.rth);
    const ITSS_p: f64 = @as(f64, model.itss);
    const m_mult: f64 = @as(f64, instance.m);

    // ------------------------------------------------------------------
    // Self-heating delta-T: read x[tnode] as f64 (see concerns).
    // ------------------------------------------------------------------
    const dt_sh: f64 = if (FLSH > 0 and RTH_p > 0.0) x[tn].val() else 0.0;
    const P = tempParams(model, instance, dt_sh);
    const vt = P.vt;
    const vt_nom = P.vt_nom;
    const r_t = P.r_t;
    const ln_rt = P.ln_rt;

    // Bandgap needed for itss_t (substrate transit charge)
    const F1VG: f64 = @as(f64, model.f1vg);
    const F2VG: f64 = @as(f64, model.f2vg);
    const VGB: f64 = @as(f64, model.vgb);
    const VGE: f64 = @as(f64, model.vge);
    const VGC: f64 = @as(f64, model.vgc);
    const VGS: f64 = @as(f64, model.vgs);
    const t_nom_k = 273.15 + @as(f64, model.tnom);
    const k1 = F1VG * t_nom_k;
    const k2 = F2VG * t_nom_k + k1 * @log(@max(t_nom_k, 1.0e-30));
    const vgb_0 = VGB - k2;
    const vge_0 = VGE - k2;
    const vgc_0 = VGC - k2;
    const vgs_0 = VGS - k2;
    const vg_cs_0 = (vgc_0 + vgs_0) / 2.0;

    const vdei_t = P.vdei_t;
    const vdci_t = P.vdci_t;
    const cjei0_t = P.cjei0_t;
    const cjci0_t = P.cjci0_t;
    const ajei_t = P.ajei_t;
    const ajci_t = P.ajci_t;

    // -- Extra T-scaled built-in voltages / caps only needed in q() --
    const VDEP_p = VDEP;
    const AJEP_p = AJEP;
    const CJEP0: f64 = @as(f64, model.cjep0);
    const CJCX0: f64 = @as(f64, model.cjcx0);
    const CJS0: f64 = @as(f64, model.cjs0);
    const CSCP0: f64 = @as(f64, model.cscp0);

    const vdep_j0 = 2.0 * vt_nom * @log(@max(@exp(@min(VDEP / (2.0 * vt_nom), 80.0)) - @exp(@min(-VDEP / (2.0 * vt_nom), 80.0)), 1.0e-30));
    const vdep_jt = vdep_j0 * r_t - mg * vt * ln_rt - ((vgb_0 + vge_0) / 2.0) * (r_t - 1.0);
    const vdep_t = vdep_jt + 2.0 * vt * @log(@max(0.5 * (1.0 + @sqrt(@max(1.0 + 4.0 * @exp(@min(-vdep_jt / vt, 80.0)), 1.0e-30))), 1.0e-30));

    const vdcx_j0 = 2.0 * vt_nom * @log(@max(@exp(@min(VDCX / (2.0 * vt_nom), 80.0)) - @exp(@min(-VDCX / (2.0 * vt_nom), 80.0)), 1.0e-30));
    const vdcx_jt = vdcx_j0 * r_t - mg * vt * ln_rt - ((vgb_0 + vgc_0) / 2.0) * (r_t - 1.0);
    const vdcx_t = vdcx_jt + 2.0 * vt * @log(@max(0.5 * (1.0 + @sqrt(@max(1.0 + 4.0 * @exp(@min(-vdcx_jt / vt, 80.0)), 1.0e-30))), 1.0e-30));

    const vds_j0 = 2.0 * vt_nom * @log(@max(@exp(@min(VDS / (2.0 * vt_nom), 80.0)) - @exp(@min(-VDS / (2.0 * vt_nom), 80.0)), 1.0e-30));
    const vds_jt = vds_j0 * r_t - mg * vt * ln_rt - vg_cs_0 * (r_t - 1.0);
    const vds_t = vds_jt + 2.0 * vt * @log(@max(0.5 * (1.0 + @sqrt(@max(1.0 + 4.0 * @exp(@min(-vds_jt / vt, 80.0)), 1.0e-30))), 1.0e-30));

    const vdsp_j0 = 2.0 * vt_nom * @log(@max(@exp(@min(VDSP / (2.0 * vt_nom), 80.0)) - @exp(@min(-VDSP / (2.0 * vt_nom), 80.0)), 1.0e-30));
    const vdsp_jt = vdsp_j0 * r_t - mg * vt * ln_rt - vg_cs_0 * (r_t - 1.0);
    const vdsp_t = vdsp_jt + 2.0 * vt * @log(@max(0.5 * (1.0 + @sqrt(@max(1.0 + 4.0 * @exp(@min(-vdsp_jt / vt, 80.0)), 1.0e-30))), 1.0e-30));

    const cjep0_t = CJEP0 * @exp(ZEP * @log(@max(VDEP / vdep_t, 1.0e-30)));
    const cjcx0_t = CJCX0 * @exp(ZCX * @log(@max(VDCX / vdcx_t, 1.0e-30)));
    const cjs0_t = CJS0 * @exp(ZS * @log(@max(VDS / vds_t, 1.0e-30)));
    const cscp0_t = CSCP0 * @exp(ZSP * @log(@max(VDSP / vdsp_t, 1.0e-30)));

    const ajep_t = AJEP_p * vdep_t / VDEP_p;
    const ajcx_t = AJCX * vdcx_t / VDCX;
    const ajs_t = AJS * vds_t / VDS;
    const ajsp_t = AJS * vdsp_t / VDSP;

    const tsf_t = TSF * @exp((ZETACX - 1.0) * ln_rt);
    const itss_t = ITSS_p * @exp((mg + 1.0 - ZETACX) * ln_rt + vgc_0 / vt * (r_t - 1.0));

    const rci0_safe = @max(P.rci0_t, 1.0e-30);

    // ========================================================================
    // Branch voltages -- S chains from here on
    // ========================================================================
    const v_biei = x[bi_n].sub(x[ei_n]).scale(type_f);
    const v_bici = x[bi_n].sub(x[ci_n]).scale(type_f);
    const v_bxei = x[bx_n].sub(x[ei_n]).scale(type_f);
    const v_bxci = x[bx_n].sub(x[ci_n]).scale(type_f);
    const v_bxbi = x[bx_n].sub(x[bi_n]).scale(type_f);
    const v_ciei = x[ci_n].sub(x[ei_n]).scale(type_f);
    const v_sici = x[si_n].sub(x[ci_n]).scale(type_f);
    const v_be = x[b_n].sub(x[e_n]).scale(type_f);
    const v_bc = x[b_n].sub(x[c_n]).scale(type_f);
    const v_ce = x[c_n].sub(x[e_n]).scale(type_f);
    const v_sc = x[s_n].sub(x[ci_n]).scale(type_f);

    // ---- Generic depletion-charge helper (punch-through form) is inlined
    // per junction below to match the original formulas exactly. ----

    // ========================================================================
    // Internal BE Depletion Charge Q_jEi (Eq 2-70)
    // ========================================================================
    const vf_ei = vdei_t * (1.0 - @exp((-1.0 / ZEI) * @log(@max(ajei_t, 1.0e-30))));
    const x_ei = v_biei.neg().addC(vf_ei).scale(1.0 / vt);
    const vj_ei = x_ei.add(x_ei.mul(x_ei).addC(a_fj).sqrt()).scale(vt / 2.0).neg().addC(vf_ei);
    const one_m_vjei = vj_ei.scale(-1.0 / vdei_t).addC(1.0).maxC(1.0e-30);
    const qjei = one_m_vjei.log().scale(1.0 - ZEI).exp().neg().addC(1.0).scale(cjei0_t * vdei_t / (1.0 - ZEI))
        .add(v_biei.sub(vj_ei).scale(ajei_t * cjei0_t));

    // ========================================================================
    // Peripheral BE Depletion Charge Q_jEp (B*E' voltage)
    // ========================================================================
    const vf_ep = vdep_t * (1.0 - @exp((-1.0 / ZEP) * @log(@max(ajep_t, 1.0e-30))));
    const x_ep = v_bxei.neg().addC(vf_ep).scale(1.0 / vt);
    const vj_ep = x_ep.add(x_ep.mul(x_ep).addC(a_fj).sqrt()).scale(vt / 2.0).neg().addC(vf_ep);
    const one_m_vjep = vj_ep.scale(-1.0 / vdep_t).addC(1.0).maxC(1.0e-30);
    const qjep = one_m_vjep.log().scale(1.0 - ZEP).exp().neg().addC(1.0).scale(cjep0_t * vdep_t / (1.0 - ZEP))
        .add(v_bxei.sub(vj_ep).scale(ajep_t * cjep0_t));

    // ========================================================================
    // Internal BC Depletion Charge Q_jCi (with punch-through)
    // ========================================================================
    const vptci_eff = VPTCI - VDCI;
    const vfci = vdci_t * (1.0 - @exp((-1.0 / ZCI) * @log(@max(ajci_t, 1.0e-30))));
    const vr_ci = 0.1 * vptci_eff + 4.0 * vt;
    const ejr = v_bici.neg().addC(vfci).scale(1.0 / vt).minC(80.0).exp();
    const vjr = ejr.addC(1.0).maxC(1.0e-30).log().scale(vt).neg().addC(vfci);
    const ejm = vjr.addC(vptci_eff).scale(1.0 / vr_ci).minC(80.0).exp();
    const vjm_const = -@as(f64, @exp(@min(-(vptci_eff + vfci) / vr_ci, 80.0)));
    const vjm = ejm.addC(1.0).maxC(1.0e-30).log().scale(vr_ci).addC(-vptci_eff + vjm_const);
    const zcir = ZCI / 4.0;
    const cjci0r = cjci0_t * @exp((ZCI - zcir) * @log(@max(vdci_t / (vptci_eff + VDCI), 1.0e-30)));
    const one_m_vjm = vjm.scale(-1.0 / vdci_t).addC(1.0).maxC(1.0e-30);
    const one_m_vjr = vjr.scale(-1.0 / vdci_t).addC(1.0).maxC(1.0e-30);
    const qjci_med = one_m_vjm.log().scale(1.0 - ZCI).exp().neg().addC(1.0).scale(cjci0_t * vdci_t / (1.0 - ZCI));
    const qjci_r = one_m_vjr.log().scale(1.0 - zcir).exp().neg().addC(1.0).scale(cjci0r * vdci_t / (1.0 - zcir));
    const qjci_cc = one_m_vjm.log().scale(1.0 - zcir).exp().neg().addC(1.0).scale(cjci0r * vdci_t / (1.0 - zcir));
    const qjci = qjci_med.add(qjci_r).sub(qjci_cc).add(v_bici.sub(vjr).scale(ajci_t * cjci0_t));

    // ========================================================================
    // External BC Depletion Charge Q_jCx (B*C' voltage)
    // ========================================================================
    const vptcx_eff = VPTCX - VDCX;
    const vfcx = vdcx_t * (1.0 - @exp((-1.0 / ZCX) * @log(@max(ajcx_t, 1.0e-30))));
    const vr_cx = 0.1 * vptcx_eff + 4.0 * vt;
    const ejr_cx = v_bxci.neg().addC(vfcx).scale(1.0 / vt).minC(80.0).exp();
    const vjr_cx = ejr_cx.addC(1.0).maxC(1.0e-30).log().scale(vt).neg().addC(vfcx);
    const ejm_cx = vjr_cx.addC(vptcx_eff).scale(1.0 / vr_cx).minC(80.0).exp();
    const vjm_cx_const = -@as(f64, @exp(@min(-(vptcx_eff + vfcx) / vr_cx, 80.0)));
    const vjm_cx = ejm_cx.addC(1.0).maxC(1.0e-30).log().scale(vr_cx).addC(-vptcx_eff + vjm_cx_const);
    const zcxr = ZCX / 4.0;
    const cjcx0r = cjcx0_t * @exp((ZCX - zcxr) * @log(@max(vdcx_t / (vptcx_eff + VDCX), 1.0e-30)));
    const one_m_vjmcx = vjm_cx.scale(-1.0 / vdcx_t).addC(1.0).maxC(1.0e-30);
    const one_m_vjrcx = vjr_cx.scale(-1.0 / vdcx_t).addC(1.0).maxC(1.0e-30);
    const qjcx_med = one_m_vjmcx.log().scale(1.0 - ZCX).exp().neg().addC(1.0).scale(cjcx0_t * vdcx_t / (1.0 - ZCX));
    const qjcx_rev = one_m_vjrcx.log().scale(1.0 - zcxr).exp().neg().addC(1.0).scale(cjcx0r * vdcx_t / (1.0 - zcxr));
    const qjcx_cor = one_m_vjmcx.log().scale(1.0 - zcxr).exp().neg().addC(1.0).scale(cjcx0r * vdcx_t / (1.0 - zcxr));
    const qjcx = qjcx_med.add(qjcx_rev).sub(qjcx_cor).add(v_bxci.sub(vjr_cx).scale(ajcx_t * cjcx0_t));

    // ========================================================================
    // C-S Bottom Depletion Charge Q_jS (S'C' voltage)
    // ========================================================================
    const vpts_eff = VPTS - VDS;
    const vfs = vds_t * (1.0 - @exp((-1.0 / ZS) * @log(@max(ajs_t, 1.0e-30))));
    const vr_s = 0.1 * vpts_eff + 4.0 * vt;
    const ejr_s = v_sici.neg().addC(vfs).scale(1.0 / vt).minC(80.0).exp();
    const vjr_s = ejr_s.addC(1.0).maxC(1.0e-30).log().scale(vt).neg().addC(vfs);
    const ejm_s = vjr_s.addC(vpts_eff).scale(1.0 / vr_s).minC(80.0).exp();
    const vjm_s_const = -@as(f64, @exp(@min(-(vpts_eff + vfs) / vr_s, 80.0)));
    const vjm_s = ejm_s.addC(1.0).maxC(1.0e-30).log().scale(vr_s).addC(-vpts_eff + vjm_s_const);
    const zsr = ZS / 4.0;
    const cjs0r = cjs0_t * @exp((ZS - zsr) * @log(@max(vds_t / (vpts_eff + VDS), 1.0e-30)));
    const one_m_vjms = vjm_s.scale(-1.0 / vds_t).addC(1.0).maxC(1.0e-30);
    const one_m_vjrs = vjr_s.scale(-1.0 / vds_t).addC(1.0).maxC(1.0e-30);
    const qjs_med = one_m_vjms.log().scale(1.0 - ZS).exp().neg().addC(1.0).scale(cjs0_t * vds_t / (1.0 - ZS));
    const qjs_rev = one_m_vjrs.log().scale(1.0 - zsr).exp().neg().addC(1.0).scale(cjs0r * vds_t / (1.0 - zsr));
    const qjs_cor = one_m_vjms.log().scale(1.0 - zsr).exp().neg().addC(1.0).scale(cjs0r * vds_t / (1.0 - zsr));
    const qjs = qjs_med.add(qjs_rev).sub(qjs_cor).add(v_sici.sub(vjr_s).scale(ajs_t * cjs0_t));

    // ========================================================================
    // Peripheral C-S Depletion Charge Q_SCp (S-C ext voltage)
    // ========================================================================
    const vptsp_eff = VPTSP - VDSP;
    const vfsp = vdsp_t * (1.0 - @exp((-1.0 / ZSP) * @log(@max(ajsp_t, 1.0e-30))));
    const vr_sp = 0.1 * vptsp_eff + 4.0 * vt;
    const ejr_sp = v_sc.neg().addC(vfsp).scale(1.0 / vt).minC(80.0).exp();
    const vjr_sp = ejr_sp.addC(1.0).maxC(1.0e-30).log().scale(vt).neg().addC(vfsp);
    const ejm_sp = vjr_sp.addC(vptsp_eff).scale(1.0 / vr_sp).minC(80.0).exp();
    const vjm_sp_const = -@as(f64, @exp(@min(-(vptsp_eff + vfsp) / vr_sp, 80.0)));
    const vjm_sp = ejm_sp.addC(1.0).maxC(1.0e-30).log().scale(vr_sp).addC(-vptsp_eff + vjm_sp_const);
    const zspr = ZSP / 4.0;
    const cscp0r = cscp0_t * @exp((ZSP - zspr) * @log(@max(vdsp_t / (vptsp_eff + VDSP), 1.0e-30)));
    const one_m_vjmsp = vjm_sp.scale(-1.0 / vdsp_t).addC(1.0).maxC(1.0e-30);
    const one_m_vjrsp = vjr_sp.scale(-1.0 / vdsp_t).addC(1.0).maxC(1.0e-30);
    const qscp_med = one_m_vjmsp.log().scale(1.0 - ZSP).exp().neg().addC(1.0).scale(cscp0_t * vdsp_t / (1.0 - ZSP));
    const qscp_rev = one_m_vjrsp.log().scale(1.0 - zspr).exp().neg().addC(1.0).scale(cscp0r * vdsp_t / (1.0 - zspr));
    const qscp_cor = one_m_vjmsp.log().scale(1.0 - zspr).exp().neg().addC(1.0).scale(cscp0r * vdsp_t / (1.0 - zspr));
    const qscp = qscp_med.add(qscp_rev).sub(qscp_cor).add(v_sc.sub(vjr_sp).scale(ajsp_t * cscp0_t));

    // ========================================================================
    // Minority (Diffusion) Charges
    // ========================================================================
    const cjei_norm = one_m_vjei.log().scale(-ZEI).exp();
    const cjci_cap = one_m_vjm.log().scale(-ZCI).exp();
    const cjci_cap_inf_pt = one_m_vjr.log().scale(-ZCI).exp();

    // h_jEi
    const hjei_val: S = blk: {
        if (P.ahjei_t > 0.0) {
            const rvt = @max(RHJEI, 0.01) * vt;
            const xu = v_biei.neg().addC(vdei_t).scale(1.0 / rvt);
            const vju = xu.add(xu.mul(xu).addC(a_fj).sqrt()).scale(rvt / 2.0).neg().addC(vdei_t);
            const u = vju.scale(-1.0 / vdei_t).addC(1.0).maxC(1.0e-30).log().scale(ZEI).exp().neg().addC(1.0).scale(P.ahjei_t);
            const u_min: f64 = 0.001;
            if (@abs(u.val()) >= u_min) {
                break :blk u.minC(80.0).exp().addC(-1.0).div(u).scale(P.hjei0_t);
            } else {
                break :blk u.scale(0.5).addC(1.0).scale(P.hjei0_t);
            }
        } else {
            break :blk S.con(P.hjei0_t);
        }
    };

    // GICCR for transfer current
    const exp_bf = v_biei.scale(1.0 / (MCF * vt)).minC(80.0).exp();
    const exp_br = v_bici.scale(1.0 / vt).minC(80.0).exp();
    const qpt_j = hjei_val.mul(qjei).add(qjci.scale(HJCI)).addC(P.qp0_t);
    const qb_rt = 0.05 * P.qp0_t;
    const x_qp = qpt_j.scale(1.0 / qb_rt).addC(-1.0);
    const qpt_low = x_qp.add(x_qp.mul(x_qp).addC(a_fj).sqrt()).scale(0.5).addC(1.0).scale(qb_rt);
    const qpt_half = qpt_low.scale(0.5);
    const qpt_sq = qpt_half.mul(qpt_half)
        .add(exp_bf.scale(P.hf0_t * P.t0_t * P.c10_t))
        .add(exp_br.scale(TR * P.c10_t));
    const qpt = qpt_half.add(qpt_sq.maxC(1.0e-30).sqrt());
    const qpt_safe = qpt.maxC(1.0e-30);
    const itf = exp_bf.scale(P.c10_t).div(qpt_safe);
    const itr = exp_br.scale(P.c10_t).div(qpt_safe);

    // Effective collector voltage
    const vceff: S = blk: {
        if (VDCK > 0.0 and FLCOMP >= 310) {
            const u_vc = v_bici.neg().addC(P.vdck_t).scale(1.0 / vt_nom);
            break :blk u_vc.add(u_vc.mul(u_vc).addC(AVCSM).sqrt()).scale(vt_nom / 2.0);
        } else {
            const u_vc = v_ciei.addC(-P.vces_t - vt).scale(1.0 / vt);
            break :blk u_vc.add(u_vc.mul(u_vc).addC(a_fj).sqrt()).scale(0.5).addC(1.0).scale(vt);
        }
    };

    // Critical current I_CK
    const vlim_safe = @max(P.vlim_t, 1.0e-30);
    const v_ratio = vceff.scale(1.0 / vlim_safe);
    const v_ratio_dck = v_ratio.maxC(1.0e-30).log().scale(DELCK).exp();
    const denom_ick = v_ratio_dck.addC(1.0).maxC(1.0e-30).log().scale(1.0 / DELCK).exp();
    const vpt_eff: f64 = if (VPT > 0.0) VPT else 1.0e30;
    const x_pt = vceff.addC(-P.vlim_t).scale(1.0 / vpt_eff);
    const pt_factor = x_pt.add(x_pt.mul(x_pt).addC(AICK).sqrt()).scale(0.5).addC(1.0);
    const ick = vceff.scale(1.0 / rci0_safe).div(denom_ick.maxC(1.0e-30)).mul(pt_factor);

    // Low-current transit time (Eq 2-34)
    const inv_c_ci = cjci_cap_inf_pt;
    const c_ci_ratio = if (inv_c_ci.val() > 1.0e-30) inv_c_ci.pow(-1.0) else S.con(1.0e30);
    const tau_f0 = inv_c_ci.addC(-1.0).scale(DT0H).add(c_ci_ratio.addC(-1.0).scale(TBVL)).addC(P.t0_t);

    // Injection width
    const itf_safe = itf.maxC(1.0e-30);
    const ick_safe = ick.maxC(1.0e-30);
    const i_ratio = ick_safe.div(itf_safe).neg().addC(1.0);
    const sqrt_1_ahc = @sqrt(1.0 + AHC);
    const w_norm = i_ratio.add(i_ratio.mul(i_ratio).addC(AHC).sqrt()).scale(1.0 / (1.0 + sqrt_1_ahc)).minC(1.0).maxC(0.0);

    // Emitter charge
    const dq_ef: S = if (TEF0 > 0.0)
        itf.div(ick_safe).maxC(1.0e-30).log().scale(GTFE).exp().scale(TEF0).mul(itf).scale(1.0 / (1.0 + GTFE))
    else
        S.con(0.0);

    // High-current charge
    const dq_fh = itf.mul(w_norm).mul(w_norm).scale(P.thcs_t);

    // BC barrier
    const dq_fh_final: S = blk: {
        if (VCBAR > 0.0 and ICBAR > 0.0) {
            const ibar = itf.sub(ick).scale(1.0 / @max(ICBAR, 1.0e-30));
            const dvcb = ibar.add(ibar.mul(ibar).addC(ACBAR).sqrt()).pow(-1.0).scale(-2.0).exp().scale(VCBAR);
            const dq_fhc = dq_fh.mul(dvcb.addC(-VCBAR).scale(1.0 / vt).minC(80.0).exp());
            const tau_bfvs = (1.0 - FTHC) * P.thcs_t;
            const dq_bfb = dvcb.scale(1.0 / vt).minC(80.0).exp().addC(-1.0).mul(itf).scale(tau_bfvs);
            break :blk dq_fhc.add(dq_bfb);
        } else {
            break :blk dq_fh;
        }
    };

    // Total forward minority charge (Eq 2-55)
    const qf = tau_f0.mul(itf).add(dq_ef).add(dq_fh_final);
    // Reverse minority charge (Eq 2-67)
    const qr = itr.scale(HR0C * TR);

    // Substrate diffusion charge (Eq 2-153)
    const itsf: S = if (itss_t > 0.0) v_bxci.scale(1.0 / (MSF * vt)).minC(80.0).exp().scale(itss_t) else S.con(0.0);
    const qds = itsf.scale(tsf_t);

    // ========================================================================
    // Parasitic Capacitances (Eq 2-142, 2-143)
    // ========================================================================
    const q_bepar1 = v_biei.scale((1.0 - FBEPAR) * CBEPAR);
    const q_bepar2 = v_be.scale(FBEPAR * CBEPAR);
    const q_bcpar1 = v_bici.scale((1.0 - FBCPAR) * CBCPAR);
    const q_bcpar2 = v_bc.scale(FBCPAR * CBCPAR);
    const q_cepar = v_ce.scale(CCEPAR);
    const q_csu = v_sici.scale(CSU);

    // Lateral NQS: C_rBi (Eq 2-147 to 2-150)
    const cde_approx = itf.scale(1.0 / vt).mul(tau_f0);
    const cdc_approx = itr.scale(TR / vt);
    const ci_total = cde_approx.add(cdc_approx).add(cjei_norm.scale(cjei0_t)).add(cjci_cap.scale(cjci0_t));
    const q_crbi = ci_total.mul(v_bxbi).scale(FCRBI);

    // Thermal capacitance
    const q_cth = x[tn].scale(CTH);

    // ========================================================================
    // Charge partitioning (internal vs peripheral)
    // ========================================================================
    const qf_int = qf.scale(FQI);
    const qf_per = qf.scale(1.0 - FQI);

    // ========================================================================
    // NQS charges (Eq 2-146)
    // ========================================================================
    // tau_f_total = tau_f0 + (TEF0>0 ? TEF0*(itf/ick_safe)^GTFE : 0)
    //             + thcs_t*w_norm^2*(1 + ick_safe/itf_safe*2/sqrt(i_ratio^2+AHC))
    const tau_ef_term: S = if (TEF0 > 0.0) itf.div(ick_safe).maxC(1.0e-30).log().scale(GTFE).exp().scale(TEF0) else S.con(0.0);
    const thcs_term = w_norm.mul(w_norm).mul(
        ick_safe.div(itf_safe).mul(i_ratio.mul(i_ratio).addC(AHC).sqrt().pow(-1.0)).scale(2.0).addC(1.0),
    ).scale(P.thcs_t);
    const tau_f_total = tau_f0.add(tau_ef_term).add(thcs_term);

    const q_xf1: S = if (FLNQS != 0) tau_f_total.mul(x[xf1_n]).scale(ALQF / vt) else S.con(0.0);
    const q_xf2: S = if (FLNQS != 0) tau_f_total.mul(x[xf2_n]).scale(ALIT / vt) else S.con(0.0);
    const q_xf: S = if (FLNQS != 0) x[xf_n].scale(1.0 / vt) else S.con(0.0);

    // ========================================================================
    // Assemble output charges (scaled by multiplier)
    // ========================================================================
    const qjei_m = qjei.scale(m_mult);
    const qjep_m = qjep.scale(m_mult);
    const qjci_m = qjci.scale(m_mult);
    const qjcx_m = qjcx.scale(m_mult);
    const qjs_m = qjs.scale(m_mult);
    const qscp_m = qscp.scale(m_mult);
    const qf_int_m = qf_int.scale(m_mult);
    const qf_per_m = qf_per.scale(m_mult);
    const qr_m = qr.scale(m_mult);
    const qds_m = qds.scale(m_mult);
    const q_bepar1_m = q_bepar1.scale(m_mult);
    const q_bepar2_m = q_bepar2.scale(m_mult);
    const q_bcpar1_m = q_bcpar1.scale(m_mult);
    const q_bcpar2_m = q_bcpar2.scale(m_mult);
    const q_cepar_m = q_cepar.scale(m_mult);
    const q_csu_m = q_csu.scale(m_mult);
    const q_crbi_m = q_crbi.scale(m_mult);

    var out: [n_u]S = undefined;

    // External collector: -q_bcpar2 + q_cepar
    out[c_n] = q_bcpar2_m.neg().add(q_cepar_m).scale(type_f);
    // External base: q_bepar2 + q_bcpar2
    out[b_n] = q_bepar2_m.add(q_bcpar2_m).scale(type_f);
    // External emitter: -q_bepar2 - q_cepar
    out[e_n] = q_bepar2_m.neg().sub(q_cepar_m).scale(type_f);
    // External substrate: 0
    out[s_n] = S.con(0.0);
    // Thermal node
    out[tn] = q_cth;
    // Intrinsic collector (ci)
    out[ci_n] = qjci_m.neg().add(qr_m.scale(FTHC)).sub(qjcx_m).sub(qjs_m).sub(qscp_m).sub(q_bcpar1_m).sub(q_csu_m).sub(qds_m).scale(type_f);
    // Intrinsic base (bi)
    out[bi_n] = qjei_m.add(qjci_m).add(qf_int_m).add(q_bepar1_m).add(q_bcpar1_m).scale(type_f);
    // Perimeter base (bx)
    out[bx_n] = qjep_m.add(qjcx_m).add(qf_per_m).add(q_crbi_m).add(qds_m).scale(type_f);
    // Intrinsic emitter (ei)
    out[ei_n] = qjei_m.neg().sub(qjep_m).sub(qf_int_m).sub(qf_per_m).sub(qr_m).scale(type_f);
    // Intrinsic substrate (si)
    out[si_n] = qjs_m.add(qscp_m).add(q_csu_m).scale(type_f);
    // NQS nodes
    out[xf_n] = q_xf.scale(m_mult);
    out[xf1_n] = q_xf1.scale(m_mult);
    out[xf2_n] = q_xf2.scale(m_mult);

    return out;
}

// ============================================================================
// Voltage Limiting (DEVpnjlim for PN junctions)
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const type_f: f64 = @floatFromInt(model.type_);
    const tnom_k = 273.15 + @as(f64, model.tnom);
    const vt = 8.617333e-5 * tnom_k;

    var result = x_new;

    // Internal BE junction: B'E' (bi - ei)
    const bi = @intFromEnum(U.bi);
    const ei = @intFromEnum(U.ei);
    const ci = @intFromEnum(U.ci);
    const bx = @intFromEnum(U.bx);
    const si = @intFromEnum(U.si);

    // DEVpnjlim: limit PN junction voltages
    // V_crit = VT * ln(VT / (sqrt(2) * IS))
    const is_be: f64 = @as(f64, model.ibeis);
    const is_bc: f64 = @as(f64, model.ibcis);
    const is_sc: f64 = @max(@as(f64, model.iscs), 1.0e-30);

    const vcrit_be = vt * @log(vt / (1.4142135 * @max(is_be, 1.0e-30)));
    const vcrit_bc = vt * @log(vt / (1.4142135 * @max(is_bc, 1.0e-30)));
    const vcrit_sc = vt * @log(vt / (1.4142135 * is_sc));

    // BE junction limiting
    const vbe_new = (x_new[bi] - x_new[ei]) * type_f;
    const vbe_old = (x_old[bi] - x_old[ei]) * type_f;
    const vbe_lim = pnjlim(vbe_new, vbe_old, vt, vcrit_be);
    const dv_be = (vbe_lim - vbe_new) * type_f;
    result[bi] += dv_be;

    // BC junction limiting (B'C')
    const vbc_new = (x_new[bi] - x_new[ci]) * type_f;
    const vbc_old = (x_old[bi] - x_old[ci]) * type_f;
    const vbc_lim = pnjlim(vbc_new, vbc_old, vt, vcrit_bc);
    const dv_bc = (vbc_lim - vbc_new) * type_f;
    result[bi] += dv_bc / 2.0;
    result[ci] -= dv_bc / 2.0;

    // Peripheral BE (B*E')
    const vbxe_new = (x_new[bx] - x_new[ei]) * type_f;
    const vbxe_old = (x_old[bx] - x_old[ei]) * type_f;
    const vbxe_lim = pnjlim(vbxe_new, vbxe_old, vt, vcrit_be);
    const dv_bxe = (vbxe_lim - vbxe_new) * type_f;
    result[bx] += dv_bxe;

    // External BC (B*C')
    const vbxc_new = (x_new[bx] - x_new[ci]) * type_f;
    const vbxc_old = (x_old[bx] - x_old[ci]) * type_f;
    const vbxc_lim = pnjlim(vbxc_new, vbxc_old, vt, vcrit_bc);
    const dv_bxc = (vbxc_lim - vbxc_new) * type_f;
    result[bx] += dv_bxc / 2.0;

    // SC junction (S'C')
    const vsc_new = (x_new[si] - x_new[ci]) * type_f;
    const vsc_old = (x_old[si] - x_old[ci]) * type_f;
    const vsc_lim = pnjlim(vsc_new, vsc_old, vt, vcrit_sc);
    const dv_sc = (vsc_lim - vsc_new) * type_f;
    result[si] += dv_sc;

    return result;
}

// PN junction voltage limiting helper
fn pnjlim(v_new: f64, v_old: f64, vt: f64, vcrit: f64) f64 {
    if (v_new > vcrit and @abs(v_new - v_old) > 2.0 * vt) {
        if (v_old > 0.0) {
            const arg = 1.0 + (v_new - v_old) / vt;
            if (arg > 0.0) {
                return v_old + vt * @log(arg);
            } else {
                return vcrit;
            }
        } else {
            return vt * @log(v_new / vt);
        }
    }
    return v_new;
}

// ============================================================================
// Parameter Stepping for Convergence Aid
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    // Scale saturation currents -- add gmin*(1-lambda) effect
    const scale: f32 = @floatCast(lambda);
    const one_m_l: f32 = @floatCast(1.0 - lambda);
    _ = one_m_l;

    // Scale junction saturation currents by lambda
    m.ibeis = model.ibeis * scale + 1.0e-30;
    m.ireis = model.ireis * scale;
    m.ibeps = model.ibeps * scale;
    m.ireps = model.ireps * scale;
    m.ibcis = model.ibcis * scale + 1.0e-30;
    m.ibcxs = model.ibcxs * scale;
    m.itss = model.itss * scale;
    m.iscs = model.iscs * scale;

    // Scale c10 (GICCR constant) -- transfer current
    m.c10 = model.c10 * scale + 1.0e-40;

    // Scale tunnelling and avalanche
    m.ibets = model.ibets * scale;
    m.ibetat0 = model.ibetat0 * scale;
    m.ibcts = model.ibcts * scale;
    m.favl = model.favl * scale;

    return m;
}

// ============================================================================
// Comptime Validation
// ============================================================================

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "hicum_l2: forward-active internal BE junction current" {
    // Default NPN. Bias only the internal BE junction: V_B'E' = 0.8 V,
    // all other nodes at 0. The dominant term at node ei is the internal BE
    // diode current ijbei = ibeis_t*(exp(v/(MBEI*vt))-1) + gmin*v.
    //
    // At tnom=27C, dt=0, dtemp=0, no self-heating:
    //   t_dev = 300.15 K, vt = 8.617333e-5 * 300.15 = 0.025865...
    //   ibeis_t = ibeis (r_t=1 so exponent=0) = 1e-18.
    //   v_biei = 0.8. exp(0.8/0.0258651) = exp(30.9299...) ~ 2.716e13.
    // We only pin the SIGN/scale via the emitter-node residual, and check the
    // internal-collector transfer current is negligible here (v_bici=0 -> exp_br=1,
    // exp_bf huge, so it ~ c10/qpt*exp_bf which is tiny given c10=2e-30).
    // Instead of a brittle absolute value we assert the physical relationship
    // it()/junction currents are finite and the emitter sinks BE current.
    const model: Model = .{};
    const inst: Instance = .{};
    var xin = [_]f64{0} ** n_u;
    xin[@intFromEnum(U.bi)] = 0.8;
    const out = contract.evalValues(Self, xin, &model, &inst, 0);

    // vt and ibeis_t computed exactly as the model does:
    const vt = 8.617333e-5 * 300.15;
    const ijbei = 1.0e-18 * (@exp(0.8 / (1.0 * vt)) - 1.0) + 1.0e-12 * 0.8;
    // Emitter node residual = (-ijbei_m - ... + it_val - i_re)*type_f. With
    // all externals grounded and rE=0 -> GSHORT short: e-node current i_re =
    // (v_e - v_ei)*g_re = 0 since both are 0. it_val at v_bici=0 is set by
    // GICCR; it is positive and enters ei with +it. The junction term
    // dominates at ei by many orders (ijbei ~ 5.7e-5 A). Check ei residual is
    // negative and of order ijbei magnitude.
    const ei_res = out[@intFromEnum(U.ei)];
    try testing.expect(ei_res < 0);
    // The BE junction current alone is ~ijbei; the emitter residual magnitude
    // must be at least that large (transfer current adds to it).
    try testing.expect(@abs(ei_res) >= ijbei * 0.5);
    try testing.expect(std.math.isFinite(ei_res));
}

test "hicum_l2: internal BE depletion charge at zero bias" {
    // Q_jEi at V_B'E' = 0. With default cjei0=1e-20, vdei=0.9, zei=0.5,
    // ajei=2.5 and everything grounded, the charge on the bi node includes
    // qjei (+ qjci + parasitics which are all ~0 for defaults with C*=0).
    // Compute qjei by hand from the OLD formula at vj_ei(v=0):
    //   vf_ei = vdei_t*(1 - ajei_t^(-1/zei))
    //   x_ei  = (vf_ei - 0)/vt
    //   vj_ei = vf_ei - vt*(x_ei + sqrt(x_ei^2 + a_fj))/2
    //   qjei  = cjei0_t*vdei_t/(1-zei)*(1-(1-vj_ei/vdei_t)^(1-zei))
    //           + ajei_t*cjei0_t*(0 - vj_ei)
    // At tnom (r_t=1), vdei_t≈vdei=0.9, cjei0_t≈cjei0=1e-20, ajei_t≈2.5.
    const model: Model = .{};
    const inst: Instance = .{};
    const xin = [_]f64{0} ** n_u;
    const out = contract.qValues(Self, xin, &model, &inst, 0);

    // Hand computation mirroring the model at r_t=1:
    const vt = 8.617333e-5 * 300.15;
    // vdei_t at r_t=1: vdei_jt = vdei_j0 - 0 - 0; the smoothing gives back ~vdei.
    // For a self-check we recompute vdei_t exactly:
    const vt_nom = vt; // r_t=1 so vt==vt_nom
    const vdei: f64 = 0.9;
    const vdei_j0 = 2.0 * vt_nom * @log(@exp(vdei / (2.0 * vt_nom)) - @exp(-vdei / (2.0 * vt_nom)));
    const vdei_jt = vdei_j0; // r_t=1: -mg*vt*0 - vg*(0)
    const vdei_t = vdei_jt + 2.0 * vt * @log(0.5 * (1.0 + @sqrt(1.0 + 4.0 * @exp(-vdei_jt / vt))));
    const zei: f64 = 0.5;
    const ajei: f64 = 2.5;
    const cjei0: f64 = 1.0e-20;
    const cjei0_t = cjei0 * @exp(zei * @log(vdei / vdei_t));
    const ajei_t = ajei * vdei_t / vdei;
    const a_fj_l: f64 = 1.921812;
    const vf_ei = vdei_t * (1.0 - @exp((-1.0 / zei) * @log(ajei_t)));
    const x_ei = vf_ei / vt;
    const vj_ei = vf_ei - vt * (x_ei + @sqrt(x_ei * x_ei + a_fj_l)) / 2.0;
    const qjei = cjei0_t * vdei_t / (1.0 - zei) * (1.0 - @exp((1.0 - zei) * @log(1.0 - vj_ei / vdei_t))) + ajei_t * cjei0_t * (0.0 - vj_ei);

    // bi node charge = (qjei + qjci + qf_int + q_bepar1 + q_bcpar1)*type_f.
    // At zero bias with defaults: qjci is the BC depletion charge at v=0
    // (nonzero), qf_int ~ 0 (t0=0, tef0=0, thcs=0), parasitics 0 (C*=0).
    // We isolate qjei's contribution by asserting the bi-node charge is finite,
    // small (~1e-20 scale), and that our hand qjei matches the model's qjei by
    // reconstructing it: recompute the model's bi minus qjci is impractical here,
    // so we assert the emitter node charge (-qjei - qjep - qf - qr) tracks -qjei.
    const q_ei = out[@intFromEnum(U.ei)];
    // qjep uses same formula with vdep=0.9 defaults => equals qjei (peripheral
    // caps cjep0=1e-20 too). So q_ei ≈ -(qjei + qjep) = -2*qjei at zero bias.
    try testing.expectApproxEqAbs(-2.0 * qjei, q_ei, @abs(qjei) * 1e-6 + 1e-30);
    try testing.expect(std.math.isFinite(q_ei));
}

test "hicum_l2: quiescent (all nodes zero) residual is finite and near-zero currents" {
    // At zero bias all junction/transfer currents vanish (exp(0)-1=0),
    // series-resistance currents vanish (all node voltages 0), so every
    // KCL residual must be ~0 (NQS/thermal shorts also see 0 volts).
    const model: Model = .{};
    const inst: Instance = .{};
    const xin = [_]f64{0} ** n_u;
    const out = contract.evalValues(Self, xin, &model, &inst, 0);
    for (out) |r| {
        try testing.expect(std.math.isFinite(r));
        try testing.expectApproxEqAbs(@as(f64, 0.0), r, 1e-9);
    }
}
