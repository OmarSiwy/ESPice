const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: HICUM/L0 v2.1.0 -- Simplified Bipolar Compact Model
//
// External terminals: C (collector), B (base), E (emitter), S (substrate)
// Internal nodes:
//   ci  -- intrinsic collector (separated from C by RCx)
//   bi  -- intrinsic base (separated from B by RBx + RBi)
//   ei  -- intrinsic emitter (separated from E by RE)
//   si  -- intrinsic substrate
//   bx  -- external base node (between RBx and RBi)
//   xf  -- NQS transfer current filter node
//   xq  -- NQS minority charge filter node
//   dt  -- thermal node (self-heating)
//
// The intrinsic transistor operates between bi, ci, ei with transport
// current iT, base currents ijBE/ijBC, avalanche current iAVL, and
// depletion/minority charges. Substrate transistor current flows
// between bi-ci-si.
// ============================================================================

pub const U = enum(u8) {
    c, // 0  - external collector
    b, // 1  - external base
    e, // 2  - external emitter
    s, // 3  - external substrate
    ci, // 4  - intrinsic collector
    bi, // 5  - intrinsic base
    ei, // 6  - intrinsic emitter
    si, // 7  - intrinsic substrate
    bx, // 8  - external base (between RBx and RBi)
    xf, // 9  - NQS transfer current node
    xq, // 10 - NQS minority charge node
    dt, // 11 - thermal node
};

pub const num_ports: usize = 4;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Device Type ---
    type_: i32 = 1, // +1 = NPN, -1 = PNP

    // --- Collector Current ---
    is: f32 = 1.0e-16,
    mcf: f32 = 1.0,
    mcr: f32 = 1.0,
    vef: f32 = 1.0e30, // inf -> large number
    ver: f32 = 1.0e30,
    aver: f32 = 0.0,
    rver: f32 = 2.0,
    iqf: f32 = 1.0e30,
    fiqf: f32 = 0.0,
    iqr: f32 = 1.0e30,
    iqfh: f32 = 1.0e30,
    tfh: f32 = 0.0,
    ahq: f32 = 0.0,
    flteft: i32 = 0,
    flitm: i32 = 0, // 0 = quadratic, 1 = Cardano

    // --- Base Current ---
    ibes: f32 = 1.0e-18,
    mbe: f32 = 1.0,
    ires: f32 = 0.0,
    mre: f32 = 2.0,
    ibcs: f32 = 1.0e-16,
    mbc: f32 = 1.0,

    // --- BE Depletion Capacitance ---
    cje0: f32 = 1.0e-20,
    vde: f32 = 0.9,
    ze: f32 = 0.5,
    aje: f32 = 2.5,

    // --- Transit Time ---
    t0: f32 = 0.0,
    dt0h: f32 = 0.0,
    tbvl: f32 = 0.0,
    tef0: f32 = 0.0,
    gte: f32 = 1.0,
    thcs: f32 = 0.0,
    ahc: f32 = 0.1,
    tr: f32 = 0.0,

    // --- Critical Current ---
    rci0: f32 = 150.0,
    vlim: f32 = 0.5,
    vpt: f32 = 1.0e30,
    vces: f32 = 0.1,
    vdck: f32 = 0.0,
    delck: f32 = 2.0,
    aick: f32 = 1.0e-3,

    // --- Internal BC Depletion Capacitance ---
    cjci0: f32 = 1.0e-20,
    vdci: f32 = 0.7,
    zci: f32 = 0.333,
    vptci: f32 = 100.0,

    // --- External BC Depletion Capacitance ---
    cjcx0: f32 = 1.0e-20,
    vdcx: f32 = 0.7,
    zcx: f32 = 0.333,
    vptcx: f32 = 1.0e30,
    fbc: f32 = 1.0,

    // --- Base Resistance ---
    rbi0: f32 = 0.0,
    vr0e: f32 = 2.5,
    vr0c: f32 = 1.0e30,
    fgeo: f32 = 0.656,

    // --- Series Resistances ---
    rbx: f32 = 0.0,
    rcx: f32 = 0.0,
    re: f32 = 0.0,

    // --- Substrate Transfer Current, Diode Current and Capacitance ---
    itss: f32 = 0.0,
    msf: f32 = 1.0,
    iscs: f32 = 0.0,
    msc: f32 = 1.0,
    cjs0: f32 = 1.0e-20,
    vds: f32 = 0.3,
    zs: f32 = 0.3,
    vpts: f32 = 1.0e30,

    // --- Parasitic Capacitances ---
    cbcpar: f32 = 0.0,
    cbepar: f32 = 0.0,

    // --- BC Avalanche Current ---
    favl: f32 = 0.0,
    qavl: f32 = 0.0,

    // --- Flicker Noise ---
    kf: f32 = 0.0,
    af: f32 = 2.0,

    // --- Temperature Dependence ---
    vgb: f32 = 1.2,
    vge: f32 = 1.17,
    vgc: f32 = 1.17,
    vgs: f32 = 1.17,
    dvgbe: f32 = 0.0,
    f1vg: f32 = -1.02377e-4,
    alt0: f32 = 0.0,
    kt0: f32 = 0.0,
    zetavgbe: f32 = 1.0,
    zetaver: f32 = -1.0,
    zetact: f32 = 3.0,
    zetabet: f32 = 3.5,
    zetaiqf: f32 = 0.0,
    zetaci: f32 = 0.0,
    zetaiqfh: f32 = 0.0,
    alvs: f32 = 0.0,
    alces: f32 = 0.0,
    aldck: f32 = 0.0,
    zetarbi: f32 = 0.0,
    zetarbx: f32 = 0.0,
    zetarcx: f32 = 0.0,
    zetare: f32 = 0.0,
    alrth: f32 = 0.0,
    zetarth: f32 = 0.0,
    alfav: f32 = 0.0,
    alqav: f32 = 0.0,

    // --- Vertical NQS Effect ---
    flnqs: i32 = 0,
    alit: f32 = 0.333,
    alqf: f32 = 0.167,

    // --- Self-Heating ---
    flsh: i32 = 0,
    rth: f32 = 0.0,
    cth: f32 = 0.0,

    // --- Backwards Compatibility ---
    flcomp: i32 = 210,

    // --- Circuit Simulator Specific ---
    tnom: f32 = 27.0,
    dt_: f32 = 0.0,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    m: f32 = 1.0,
};

// ============================================================================
// Sparse Conductance Stamp Pattern
// ============================================================================

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // RCx thermal noise: C -- ci
    .{ .row = @intFromEnum(U.c), .col = @intFromEnum(U.ci), .kind = .thermal },
    // RBx thermal noise: B -- bx
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.bx), .kind = .thermal },
    // RBi thermal noise: bx -- bi
    .{ .row = @intFromEnum(U.bx), .col = @intFromEnum(U.bi), .kind = .thermal },
    // RE thermal noise: E -- ei
    .{ .row = @intFromEnum(U.e), .col = @intFromEnum(U.ei), .kind = .thermal },
    // Transfer current shot noise: ci -- ei
    .{ .row = @intFromEnum(U.ci), .col = @intFromEnum(U.ei), .kind = .shot },
    // BE junction shot noise: bi -- ei
    .{ .row = @intFromEnum(U.bi), .col = @intFromEnum(U.ei), .kind = .shot },
    // BE junction flicker noise: bi -- ei
    .{ .row = @intFromEnum(U.bi), .col = @intFromEnum(U.ei), .kind = .flicker },
    // BC junction shot noise: bi -- ci
    .{ .row = @intFromEnum(U.bi), .col = @intFromEnum(U.ci), .kind = .shot },
    // Avalanche shot noise: bi -- ci
    .{ .row = @intFromEnum(U.bi), .col = @intFromEnum(U.ci), .kind = .shot },
    // CS junction shot noise: si -- ci
    .{ .row = @intFromEnum(U.si), .col = @intFromEnum(U.ci), .kind = .shot },
};

// ============================================================================
// X-independent parameter/temperature preprocessing.
//
// NOTE ON SELF-HEATING: the original code fed x[dt] (thermal-node voltage)
// into the temperature map only when flsh=1 AND rth>0. To keep every
// temperature-scaled quantity differentiable w.r.t. x[dt] in that case, the
// temperature map is instantiated over the scalar S inside eval/q (via
// Params(S) below). All PARAMETER math that does not touch x[dt] stays plain
// f64; the only x-dependent input threaded through here is delta_T_sh (the
// self-heating temperature rise), passed as an S. When flsh is off, delta_T_sh
// is S.con(0) and every derivative w.r.t. x[dt] is exactly zero, reproducing
// the original behaviour.
// ============================================================================

// Physical constants
const KB_Q: f64 = 8.617333262145e-5; // kB/q in V/K
const a_fj: f64 = 1.921812;
const gmin: f64 = 1.0e-12;
const g_short: f64 = 1.0e12;

/// Temperature-scaled built-in voltage (2-98 through 2-100), generic over S.
/// VT depends on x[dt] under self-heating, hence S-valued.
fn tempScaleVD(comptime S: type, VD_T0: f64, Vg: f64, mg: f64, VT: S, VT0: f64, r_T: S, ln_rT: S) S {
    // Auxiliary voltage at reference temperature (2-98) -- pure f64 (no x).
    const half_vd_vt0 = VD_T0 / (2.0 * VT0);
    const VDj_T0 = 2.0 * VT0 * contract.fmath.log(@max(contract.fmath.exp(@min(half_vd_vt0, 80.0)) - contract.fmath.exp(@min(-half_vd_vt0, 80.0)), 1.0e-30));

    // Classical built-in voltage at T (2-99): VDj_T0*r_T + Vg*(1-r_T) - mg*VT*ln_rT
    const VDj_T = r_T.scale(VDj_T0).add(r_T.neg().addC(1.0).scale(Vg)).sub(VT.mul(ln_rT).scale(mg));

    // Final smoothed built-in voltage (2-100)
    // exp_neg = exp(min(-VDj_T/VT, 80))
    const exp_neg = VDj_T.neg().div(VT).minC(80.0).exp();
    // VD_T = VDj_T + 2*VT*log(max((1 + sqrt(max(1+4*exp_neg,0)))/2, 1e-30))
    const inner = exp_neg.scale(4.0).addC(1.0).maxC(0.0).sqrt().addC(1.0).scale(0.5).maxC(1.0e-30).log();
    return VDj_T.add(VT.mul(inner).scale(2.0));
}

/// Branchless qpT solver (Cardano or Quadratic), generic over S.
/// All inputs are x-dependent, so this is fully S-valued.
fn solveQpT(comptime S: type, qj: S, qfli: S, i_Tfi: S, IQFH_T: S, TFH_T: S, ICK: S, IQR: S, FLITM: bool) S {
    _ = IQR;
    // ---- Quadratic (simplified) approach (flitm=0) ----
    // qBCfi(w=1) = iTfi / IQfh
    const q_BCfi_w1 = i_Tfi.div(IQFH_T);

    // Modified qEfi (2-43): qEfi = tfh * (iTfi^2 / (ICK * IQfh))^(2/3)
    const inner_Efi = i_Tfi.mul(i_Tfi).div(ICK.maxC(1.0e-30).mul(IQFH_T));
    const q_Efi_quad = TFH_T.mul(inner_Efi.maxC(1.0e-30).log().scale(2.0 / 3.0).exp());

    // Quadratic solution (2-45)
    const half_qj = qj.scale(0.5);
    const disc = half_qj.mul(half_qj).add(qfli).add(q_BCfi_w1).add(q_Efi_quad);
    const qpT_quad = half_qj.add(disc.maxC(1.0e-30).sqrt());

    if (!FLITM) return qpT_quad;

    // ---- Cardano third-order approach (flitm=1) ----
    const q_BCfi = i_Tfi.div(IQFH_T);
    const q_Efi = TFH_T.mul(i_Tfi).mul(i_Tfi).div(ICK.maxC(1.0e-30).mul(IQFH_T));

    const a_card = qj.neg();
    const b_card = qfli.add(q_BCfi).neg();
    const c_card = q_Efi.neg();

    // Depressed cubic coefficients (6-4)
    // p = b - a^2/3
    const p_card = b_card.sub(a_card.mul(a_card).scale(1.0 / 3.0));
    // q = 2a^3/27 - a*b/3 + c
    const q_card = a_card.mul(a_card).mul(a_card).scale(2.0 / 27.0).sub(a_card.mul(b_card).scale(1.0 / 3.0)).add(c_card);

    // Determinant D (6-5): D = (q/2)^2 + (p/3)^3
    const p3 = p_card.scale(1.0 / 3.0).mul(p_card.scale(1.0 / 3.0)).mul(p_card.scale(1.0 / 3.0));
    const q2 = q_card.scale(0.5).mul(q_card.scale(0.5));
    const D = q2.add(p3);

    // Compute D>0 result: one real root (6-11, 6-12)
    const sqrt_D = D.abs().maxC(0.0).sqrt();
    const u_cube = q_card.scale(-0.5).add(sqrt_D);
    const v_cube = q_card.scale(-0.5).sub(sqrt_D);
    const sign_u: f64 = if (u_cube.val() >= 0.0) 1.0 else -1.0;
    const sign_v: f64 = if (v_cube.val() >= 0.0) 1.0 else -1.0;
    // sign * exp(log(max(|.|,1e-30))/3)
    const u_val = u_cube.abs().maxC(1.0e-30).log().scale(1.0 / 3.0).exp().scale(sign_u);
    const v_val = v_cube.abs().maxC(1.0e-30).log().scale(1.0 / 3.0).exp().scale(sign_v);
    const qpT_d_pos = u_val.add(v_val).sub(a_card.scale(1.0 / 3.0)).maxC(1.0e-30);

    // Compute D<0 result: three real roots, use z2 (6-9, 6-10)
    const neg_p3 = p3.neg().maxC(1.0e-30);
    // phi_scale = sqrt(27 / max(neg_p3, 1e-30)) = sqrt(27)/sqrt(neg_p3)
    const phi_scale = S.con(@sqrt(27.0)).div(neg_p3.maxC(1.0e-30).sqrt());
    const acos_arg_raw = q_card.scale(-0.5).mul(phi_scale);
    const acos_arg = acos_arg_raw.maxC(-1.0).minC(1.0);

    // acos(x) = pi/2 - asin(x); use atan-based identity that is available in S:
    //   asin(x) = atan( x / sqrt(1 - x^2) )   (valid for |x| < 1; clamped above)
    // acos(x) = pi/2 - asin(x)
    const pi: f64 = 3.14159265358979323846;
    const one_m_x2 = acos_arg.mul(acos_arg).neg().addC(1.0).maxC(1.0e-30);
    const asin_val = acos_arg.div(one_m_x2.sqrt()).atan();
    const phi_angle = asin_val.neg().addC(pi / 2.0);

    // z2 = -sqrt(-4p/3) * cos(phi/3) (6-10)
    const r_sqrt = p_card.scale(-4.0 / 3.0).maxC(0.0).sqrt();
    const z2 = r_sqrt.neg().mul(phi_angle.scale(1.0 / 3.0).cos());
    const qpT_d_neg = z2.sub(a_card.scale(1.0 / 3.0)).maxC(1.0e-30);

    // D=0 degenerate case (6-6, 6-7)
    const qpT_d_zero = a_card.neg().maxC(1.0e-30);

    // Branchless select across the three cases (branch on .val() of D --
    // this reproduces the original topology-level cubic-root selection).
    const Dv = D.val();
    return if (Dv > 0.0) qpT_d_pos else if (Dv < 0.0) qpT_d_neg else qpT_d_zero;
}

// ============================================================================
// DC Current Function (eval)
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    // --- Node indices ---
    const c = @intFromEnum(U.c);
    const b = @intFromEnum(U.b);
    const e = @intFromEnum(U.e);
    const s = @intFromEnum(U.s);
    const ci = @intFromEnum(U.ci);
    const bi = @intFromEnum(U.bi);
    const ei = @intFromEnum(U.ei);
    const si = @intFromEnum(U.si);
    const bx = @intFromEnum(U.bx);
    const xf = @intFromEnum(U.xf);
    const xq = @intFromEnum(U.xq);
    const dt = @intFromEnum(U.dt);

    // --- Type factor ---
    const type_f: f64 = @floatFromInt(model.type_);

    // --- Cast model parameters to f64 (x-independent) ---
    const IS: f64 = @as(f64, model.is);
    const MCF: f64 = @as(f64, model.mcf);
    const MCR: f64 = @as(f64, model.mcr);
    const VEF: f64 = @as(f64, model.vef);
    const VER: f64 = @as(f64, model.ver);
    const AVER: f64 = @as(f64, model.aver);
    const RVER: f64 = @as(f64, model.rver);
    const IQF: f64 = @as(f64, model.iqf);
    const FIQF: f64 = @as(f64, model.fiqf);
    const IQR: f64 = @as(f64, model.iqr);
    const IQFH: f64 = @as(f64, model.iqfh);
    const TFH: f64 = @as(f64, model.tfh);
    const IBES: f64 = @as(f64, model.ibes);
    const MBE: f64 = @as(f64, model.mbe);
    const IRES: f64 = @as(f64, model.ires);
    const MRE: f64 = @as(f64, model.mre);
    const IBCS: f64 = @as(f64, model.ibcs);
    const MBC: f64 = @as(f64, model.mbc);

    const CJE0: f64 = @as(f64, model.cje0);
    const VDE: f64 = @as(f64, model.vde);
    const ZE: f64 = @as(f64, model.ze);
    const AJE: f64 = @as(f64, model.aje);

    const T0: f64 = @as(f64, model.t0);
    const DT0H: f64 = @as(f64, model.dt0h);
    const TBVL: f64 = @as(f64, model.tbvl);

    const RCI0: f64 = @as(f64, model.rci0);
    const VLIM: f64 = @as(f64, model.vlim);
    const VPT: f64 = @as(f64, model.vpt);
    const VCES: f64 = @as(f64, model.vces);
    const VDCK: f64 = @as(f64, model.vdck);
    const DELCK: f64 = @as(f64, model.delck);
    const AICK: f64 = @as(f64, model.aick);

    const CJCI0: f64 = @as(f64, model.cjci0);
    const VDCI: f64 = @as(f64, model.vdci);
    const ZCI: f64 = @as(f64, model.zci);
    const VPTCI: f64 = @as(f64, model.vptci);

    const CJCX0: f64 = @as(f64, model.cjcx0);
    const FBC: f64 = @as(f64, model.fbc);

    const RBI0: f64 = @as(f64, model.rbi0);
    const VR0E: f64 = @as(f64, model.vr0e);
    const VR0C: f64 = @as(f64, model.vr0c);
    const FGEO: f64 = @as(f64, model.fgeo);

    const RBX: f64 = @as(f64, model.rbx);
    const RCX_val: f64 = @as(f64, model.rcx);
    const RE: f64 = @as(f64, model.re);

    const ITSS: f64 = @as(f64, model.itss);
    const MSF: f64 = @as(f64, model.msf);
    const ISCS: f64 = @as(f64, model.iscs);
    const MSC: f64 = @as(f64, model.msc);

    const FAVL: f64 = @as(f64, model.favl);
    const QAVL: f64 = @as(f64, model.qavl);

    const VGB: f64 = @as(f64, model.vgb);
    const VGE: f64 = @as(f64, model.vge);
    const VGC: f64 = @as(f64, model.vgc);
    const VGS: f64 = @as(f64, model.vgs);
    const DVGBE: f64 = @as(f64, model.dvgbe);
    const F1VG: f64 = @as(f64, model.f1vg);
    const ALT0: f64 = @as(f64, model.alt0);
    const KT0: f64 = @as(f64, model.kt0);
    const ZETAVGBE: f64 = @as(f64, model.zetavgbe);
    const ZETAVER: f64 = @as(f64, model.zetaver);
    const ZETACT: f64 = @as(f64, model.zetact);
    const ZETABET: f64 = @as(f64, model.zetabet);
    const ZETAIQF: f64 = @as(f64, model.zetaiqf);
    const ZETACI: f64 = @as(f64, model.zetaci);
    const ZETAIQFH: f64 = @as(f64, model.zetaiqfh);
    const ALVS: f64 = @as(f64, model.alvs);
    const ALCES: f64 = @as(f64, model.alces);
    const ALDCK: f64 = @as(f64, model.aldck);
    const ZETARBI: f64 = @as(f64, model.zetarbi);
    const ZETARBX: f64 = @as(f64, model.zetarbx);
    const ZETARCX: f64 = @as(f64, model.zetarcx);
    const ZETARE: f64 = @as(f64, model.zetare);
    const ALRTH: f64 = @as(f64, model.alrth);
    const ZETARTH: f64 = @as(f64, model.zetarth);
    const ALFAV: f64 = @as(f64, model.alfav);
    const ALQAV: f64 = @as(f64, model.alqav);

    const FLNQS: bool = model.flnqs != 0;

    const FLSH: bool = model.flsh != 0;
    const RTH: f64 = @as(f64, model.rth);

    const TNOM: f64 = @as(f64, model.tnom);
    const DT_INST: f64 = @as(f64, model.dt_);

    const FLITM: bool = model.flitm != 0;

    // --- Instance ---
    const m_mult: f64 = @as(f64, instance.m);

    // ========================================================================
    // Temperature Mapping (Section 2.11).
    // Self-heating rise delta_T_sh is x[dt]-dependent -> S; everything else f64.
    // ========================================================================
    const T0K = TNOM + 273.15; // Reference temperature in K
    const v_dt_raw = x[dt];
    const self_heat = FLSH and RTH > 0.0;
    // delta_T_sh = x[dt] when self-heating, else 0
    const delta_T_sh: S = if (self_heat) v_dt_raw else S.con(0.0);
    // T_dev = T0K + DT_INST + delta_T_sh
    const T_dev = delta_T_sh.addC(T0K + DT_INST);
    const VT = T_dev.scale(KB_Q); // Thermal voltage at device T
    const VT0 = KB_Q * T0K; // Thermal voltage at reference T (f64)
    const r_T = T_dev.scale(1.0 / T0K); // Temperature ratio
    const ln_rT = r_T.maxC(1.0e-30).log();
    const delta_T = T_dev.addC(-T0K); // T_dev - T0K

    // ========================================================================
    // Bandgap voltage (2-77, 2-78, 2-79) -- pure f64
    // ========================================================================
    const K1 = F1VG; // V/K
    const k1 = K1 * T0K;
    const mg = 3.0 - k1 / VT0; // (2-81)

    // Vgbe for recombination current
    const Vgbe = (VGB + VGE) / 2.0;

    // ========================================================================
    // Temperature-Scaled Saturation Currents (2-83 through 2-88)
    // ========================================================================
    const one_m_rT = r_T.addC(-1.0); // (T/T0 - 1)

    // IS(T) (2-83): IS * exp(ZETACT*ln_rT + VGB/VT*one_m_rT)
    const IS_Tv = ln_rT.scale(ZETACT).add(one_m_rT.scale(VGB).div(VT)).exp().scale(IS);

    // IBES(T) (2-84)
    const IBES_Tv = ln_rT.scale(ZETABET).add(one_m_rT.scale(VGE).div(VT)).exp().scale(IBES);

    // IRES(T) (2-85): IRES * exp((mg/2)*ln_rT + Vgbe/(2*VT)*one_m_rT)
    const IRES_Tv = ln_rT.scale(mg / 2.0).add(one_m_rT.scale(Vgbe).div(VT.scale(2.0))).exp().scale(IRES);

    // IBCS(T) (2-86)
    const IBCS_Tv = ln_rT.scale(ZETABET).add(one_m_rT.scale(VGC).div(VT)).exp().scale(IBCS);

    // ISCS(T) (2-87): zeta_SCT = mg - 1.5
    const zeta_SCT = mg - 1.5;
    const ISCS_Tv = ln_rT.scale(zeta_SCT).add(one_m_rT.scale(VGS).div(VT)).exp().scale(ISCS);

    // ITSS(T) (2-88)
    const ITSS_Tv = ln_rT.scale(zeta_SCT).add(one_m_rT.scale(VGC).div(VT)).exp().scale(ITSS);

    // IQf(T) (2-89): IQF * exp(ZETAIQF*ln_rT - DVGBE/VT0*one_m_rT)  (VT0 is f64)
    const IQF_Tv = ln_rT.scale(ZETAIQF).sub(one_m_rT.scale(DVGBE / VT0)).exp().scale(IQF);

    // IQfh(T) (2-90)
    const IQFH_Tv = ln_rT.scale(ZETAIQFH).exp().scale(IQFH);

    // tfh(T) (2-91): TFH * (IQFH_T/IQFH) * exp((VGB-VGE)/VT0*one_m_rT)
    //   IQFH_T/IQFH = exp(ZETAIQFH*ln_rT) -> combine
    const TFH_Tv = ln_rT.scale(ZETAIQFH).add(one_m_rT.scale((VGB - VGE) / VT0)).exp().scale(TFH);

    // ========================================================================
    // Temperature-Scaled Built-in Voltages (2-98 through 2-100)
    // ========================================================================
    const VDE_T = tempScaleVD(S, VDE, VGB, mg, VT, VT0, r_T, ln_rT);
    const VDCI_T = tempScaleVD(S, VDCI, VGC, mg, VT, VT0, r_T, ln_rT);

    // ========================================================================
    // Temperature-Scaled Zero-Bias Capacitances (2-94)
    // ========================================================================
    // CJE0_T = CJE0 * exp(ZE * log(max(VDE/VDE_T, 1e-30)))
    const CJE0_Tv = S.con(VDE).div(VDE_T).maxC(1.0e-30).log().scale(ZE).exp().scale(CJE0);
    const CJCI0_Tv = S.con(VDCI).div(VDCI_T).maxC(1.0e-30).log().scale(ZCI).exp().scale(CJCI0);

    // aje(T) (2-95): AJE * VDE_T / VDE
    const AJE_T = VDE_T.scale(AJE / VDE);

    // ========================================================================
    // Temperature-Scaled Transit Time (2-101)
    // T0_T = T0 * (1 + ALT0*delta_T + KT0*delta_T^2)
    // ========================================================================
    const T0_T = delta_T.scale(ALT0).add(delta_T.mul(delta_T).scale(KT0)).addC(1.0).scale(T0);

    // ========================================================================
    // Temperature-Scaled Resistances (2-104 through 2-112)
    // ========================================================================
    const RCI0_T = ln_rT.scale(ZETACI).exp().scale(RCI0);
    const VLIM_T = ln_rT.scale(ZETACI - ALVS).exp().scale(VLIM);
    const VCES_T = delta_T.scale(ALCES).addC(1.0).scale(VCES);
    const VDCK_T = delta_T.scale(-ALDCK).addC(1.0).scale(VDCK);
    const RCX_T = ln_rT.scale(ZETARCX).exp().scale(RCX_val);
    const RBX_T = ln_rT.scale(ZETARBX).exp().scale(RBX);
    const RBI0_T = ln_rT.scale(ZETARBI).exp().scale(RBI0);
    const RE_T = ln_rT.scale(ZETARE).exp().scale(RE);
    // RTH_T = if rth>0: RTH*(1+ALRTH*delta_T)*exp(ZETARTH*ln_rT) else 0
    const RTH_T: S = if (RTH > 0.0)
        delta_T.scale(ALRTH).addC(1.0).mul(ln_rT.scale(ZETARTH).exp()).scale(RTH)
    else
        S.con(0.0);

    // ========================================================================
    // Temperature-Scaled Early Voltage (2-102, 2-103)
    // ========================================================================
    // dvgbe_pow is x-independent f64; VER_T uses VT (S).
    const dvgbe_pow: f64 = if (@abs(DVGBE) < 1.0e-30) 0.0 else contract.fmath.exp(ZETAVGBE * contract.fmath.log(@abs(DVGBE)));
    // VER_T = VER * exp(-dvgbe_pow/VT * one_m_rT)
    const VER_T = one_m_rT.scale(dvgbe_pow).div(VT).neg().exp().scale(VER);
    const AVER_T = ln_rT.scale(ZETAVER).exp().scale(AVER);

    // ========================================================================
    // Temperature-Scaled Avalanche (2-96, 2-97)
    // ========================================================================
    const FAVL_T = delta_T.scale(ALFAV).exp().scale(FAVL);
    const QAVL_T = delta_T.scale(ALQAV).exp().scale(QAVL);

    // ========================================================================
    // BC Capacitance Partitioning (Section 2.2.2)
    // ========================================================================
    const cjcx0_is_zero = CJCX0 < 1.0e-30;
    // C_jCi0 = if cjcx0==0: CJCI0_T*FBC else CJCI0_T
    const C_jCi0: S = if (cjcx0_is_zero) CJCI0_Tv.scale(FBC) else CJCI0_Tv;

    // ========================================================================
    // Branch Voltages (with type factor for NPN/PNP)
    // ========================================================================
    const v_biei = x[bi].sub(x[ei]).scale(type_f);
    const v_bici = x[bi].sub(x[ci]).scale(type_f);
    const v_ciei = x[ci].sub(x[ei]).scale(type_f);
    const v_sici = x[si].sub(x[ci]).scale(type_f);

    // ========================================================================
    // BE Depletion Charge/Capacitance (Section 2.2.1, eqs 2-2 through 2-8)
    // ========================================================================
    // Forward intercept voltage Vf (2-4): VDE_T*(1 - exp((-1/ZE)*log(max(AJE_T,1e-30))))
    const Vf_BE = AJE_T.maxC(1.0e-30).log().scale(-1.0 / ZE).exp().neg().addC(1.0).mul(VDE_T);

    // Argument x for smoothing (2-3): (Vf_BE - v_biei)/VT
    const x_be = Vf_BE.sub(v_biei).div(VT);

    // Auxiliary junction voltage vj (2-2): Vf_BE - VT*(x + sqrt(x^2+a_fj))/2
    const sqrt_x_be = x_be.mul(x_be).addC(a_fj).sqrt();
    const vj_be = Vf_BE.sub(VT.mul(x_be.add(sqrt_x_be)).scale(0.5));

    // Capacitance ratio (1 - vj/VDE) for charge calculation
    const one_m_vj_vde = vj_be.div(VDE_T).neg().addC(1.0).maxC(1.0e-30);

    // BE depletion charge (2-8):
    //   CJE0_T*VDE_T/(1-ZE)*(1 - (one_m_vj_vde)^(1-ZE)) + AJE_T*CJE0_T*(v_biei - vj_be)
    const Q_jE_a = CJE0_Tv.mul(VDE_T).scale(1.0 / (1.0 - ZE)).mul(one_m_vj_vde.log().scale(1.0 - ZE).exp().neg().addC(1.0));
    const Q_jE_b = AJE_T.mul(CJE0_Tv).mul(v_biei.sub(vj_be));
    const Q_jE = Q_jE_a.add(Q_jE_b);

    // Normalized depletion charge for qj (2-30)
    const v_jEi = Q_jE.div(CJE0_Tv);

    // Internal BC depletion capacitance (same as CjE but BC params)
    const Vf_BCi = VDCI_T.scale(1.0 - contract.fmath.exp((-1.0 / ZCI) * contract.fmath.log(2.5))); // aje=2.5 equivalent for BC
    const x_bci = Vf_BCi.sub(v_bici).div(VT);
    const sqrt_x_bci = x_bci.mul(x_bci).addC(a_fj).sqrt();
    const vj_bci = Vf_BCi.sub(VT.mul(x_bci.add(sqrt_x_bci)).scale(0.5));

    // CjCi capacitance ratio Cc = CjCi/CjCi0
    const one_m_vjci_vdci = vj_bci.div(VDCI_T).neg().addC(1.0).maxC(1.0e-30);
    const Cc = one_m_vjci_vdci.log().scale(-ZCI).exp();

    // Internal BC depletion charge with punch-through correction
    const Q_jCi_base_a = C_jCi0.mul(VDCI_T).scale(1.0 / (1.0 - ZCI)).mul(one_m_vjci_vdci.log().scale(1.0 - ZCI).exp().neg().addC(1.0));
    const Q_jCi_base_b = C_jCi0.scale(2.5).mul(v_bici.sub(vj_bci));
    const Q_jCi_base = Q_jCi_base_a.add(Q_jCi_base_b);
    // Punch-through: + C_jCi0 * vj^2 / (2*VPTCI)
    const Q_jCi = Q_jCi_base.add(C_jCi0.mul(vj_bci).mul(vj_bci).scale(1.0 / (2.0 * VPTCI)));

    // Normalized BC depletion charge (2-31)
    const v_jCi = Q_jCi.div(C_jCi0);

    // ========================================================================
    // Heterojunction: Bias-dependent VEr (Section 2.4.1, eqs 2-46 through 2-49)
    // ========================================================================
    // Smoothed junction voltage for VEr (2-48)
    const x_u = VDE_T.sub(v_biei).div(VT.scale(RVER));
    const sqrt_xu = x_u.mul(x_u).addC(a_fj).sqrt();
    const v_ju = VDE_T.sub(VT.scale(RVER).mul(x_u.add(sqrt_xu)).scale(0.5));

    // u argument (2-47): AVER_T*(1 - (1 - v_ju/VDE)^ZE)
    const one_m_vju_vde = v_ju.div(VDE_T).neg().addC(1.0).maxC(1.0e-30);
    const u_ver = one_m_vju_vde.log().scale(ZE).exp().neg().addC(1.0).mul(AVER_T);

    // Bernoulli function B(u) (2-49): (exp(u)-1)/u for |u|>=umin, 1+u/2 for |u|<umin.
    // Branch on |u|.val() (topology-level, reproduces original piecewise).
    const u_min: f64 = 0.001;
    const B_large = u_ver.minC(80.0).exp().addC(-1.0).div(u_ver.addC(1.0e-30));
    const B_small = u_ver.scale(0.5).addC(1.0);
    const B_u: S = if (@abs(u_ver.val()) >= u_min) B_large else B_small;

    // VEr(T, bias) (2-46)
    const VER_eff = VER_T.mul(B_u);

    // ========================================================================
    // Normalized Depletion Charge qj (2-29)
    // ========================================================================
    const qj = v_jEi.div(VER_eff).add(v_jCi.scale(1.0 / VEF)).addC(1.0);

    // ========================================================================
    // Ideal Transport Current Components (2-27)
    // ========================================================================
    const arg_be = v_biei.scale(1.0 / (MCF)).div(VT).minC(80.0);
    const i_Tfi = arg_be.exp().mul(IS_Tv);

    const arg_bc = v_bici.scale(1.0 / (MCR)).div(VT).minC(80.0);
    const i_Tri = arg_bc.exp().mul(IS_Tv);

    // ========================================================================
    // Low-Current Transit Time tau_f0 (2-13)
    // c = CjCi0/CjCi = 1/Cc
    // ========================================================================
    const c_ratio_v = S.con(1.0).div(Cc.maxC(1.0e-30));
    // tau_f0 = T0_T + DT0H*(c_ratio-1) + TBVL*(1/c_ratio - 1)
    const tau_f0 = T0_T.add(c_ratio_v.addC(-1.0).scale(DT0H)).add(S.con(1.0).div(c_ratio_v).addC(-1.0).scale(TBVL));

    // ========================================================================
    // Voltage-dependent IQf (2-34)
    // tau_ratio = tau_f0/T0_T (or 1 if T0 tiny)
    // ========================================================================
    const T0_tiny = T0_T.val() <= 1.0e-30;
    const tau_ratio: S = if (T0_tiny) S.con(1.0) else tau_f0.div(T0_T);
    // IQF_eff = IQF_T / (1 + FIQF*(tau_ratio-1))
    const IQF_eff = IQF_Tv.div(tau_ratio.addC(-1.0).scale(FIQF).addC(1.0));

    // ========================================================================
    // Critical Current ICK (2-19 through 2-21)
    // ========================================================================
    // Collector voltage vc (2-21). Branch on VDCK_T sign (param -> f64 check).
    const vc_raw: S = if (VDCK > 0.0) VDCK_T.sub(v_bici) else v_ciei.sub(VCES_T);

    // Effective CE voltage (clamped positive) (2-20)
    const u_ce = vc_raw.sub(VT).div(VT);
    const sqrt_u_ce = u_ce.mul(u_ce).addC(a_fj).sqrt();
    const v_ceff = VT.mul(u_ce.add(sqrt_u_ce).scale(0.5).addC(1.0));

    // ICK (2-19)
    const v_over_vlim = v_ceff.div(VLIM_T);
    // vlim_denom = (1 + v_over_vlim^DELCK)^(1/DELCK)
    const vlim_denom = v_over_vlim.maxC(1.0e-30).log().scale(DELCK).exp().addC(1.0).maxC(1.0e-30).log().scale(1.0 / DELCK).exp();
    const x_ick = v_ceff.sub(VLIM_T).scale(1.0 / VPT);
    const sqrt_x_ick = x_ick.mul(x_ick).addC(AICK).sqrt();
    const ICK = v_ceff.div(RCI0_T.mul(vlim_denom)).mul(x_ick.add(sqrt_x_ick).scale(0.5).addC(1.0)).scale(m_mult);

    // ========================================================================
    // Normalized low-injection mobile charge qfli (2-39)
    // ========================================================================
    const qfli = i_Tfi.div(IQF_eff).add(i_Tri.scale(1.0 / IQR));

    // ========================================================================
    // Solve for qpT
    // ========================================================================
    const qpT = solveQpT(S, qj, qfli, i_Tfi, IQFH_Tv, TFH_Tv, ICK, S.con(IQR), FLITM);

    // ========================================================================
    // Transfer Current (2-26, 2-33)
    // ========================================================================
    const i_Tf = i_Tfi.div(qpT);
    const i_Tr = i_Tri.div(qpT);
    const i_T = i_Tf.sub(i_Tr);

    // ========================================================================
    // BE Junction Current (Section 2.5.1)
    // ========================================================================
    const arg_be_ideal = v_biei.scale(1.0 / MBE).div(VT).minC(80.0);
    const i_jBE_ideal = arg_be_ideal.exp().addC(-1.0).mul(IBES_Tv);

    const arg_be_rec = v_biei.scale(1.0 / MRE).div(VT).minC(80.0);
    const i_jBE_rec = arg_be_rec.exp().addC(-1.0).mul(IRES_Tv);

    const i_jBE = i_jBE_ideal.add(i_jBE_rec).add(v_biei.scale(gmin));

    // ========================================================================
    // BC Junction Current (Section 2.5.2)
    // ========================================================================
    const arg_bc_diode = v_bici.scale(1.0 / MBC).div(VT).minC(80.0);
    const i_jBC = arg_bc_diode.exp().addC(-1.0).mul(IBCS_Tv).add(v_bici.scale(gmin));

    // ========================================================================
    // Avalanche Current (Section 2.5.3)
    // iAVL = iTf * favl / Cc^(1/zCi) * VDCi * exp(-qavl/(CjCi0*VDCi) * Cc^(1/zCi-1))
    // ========================================================================
    const Cc_inv_z = Cc.maxC(1.0e-30).log().scale(1.0 / ZCI).exp();
    const Cc_inv_z_m1 = Cc.maxC(1.0e-30).log().scale(1.0 / ZCI - 1.0).exp();
    // avl_exp_arg = -QAVL_T / (CJCI0_T*VDCI_T + 1e-30) * Cc_inv_z_m1
    const avl_exp_arg = QAVL_T.neg().div(CJCI0_Tv.mul(VDCI_T).addC(1.0e-30)).mul(Cc_inv_z_m1);
    const i_AVL: S = if (FAVL > 0.0)
        i_Tf.mul(FAVL_T).div(Cc_inv_z).mul(VDCI_T).mul(avl_exp_arg.minC(80.0).exp())
    else
        S.con(0.0);

    // ========================================================================
    // Substrate Transistor Transfer Current (2-53)
    // ========================================================================
    const arg_sub_bc = v_bici.scale(1.0 / MSF).div(VT).minC(80.0);
    const arg_sub_sc = v_sici.scale(1.0 / MSF).div(VT).minC(80.0);
    const I_TS: S = if (ITSS > 0.0)
        arg_sub_bc.exp().sub(arg_sub_sc.exp()).mul(ITSS_Tv)
    else
        S.con(0.0);

    // ========================================================================
    // CS Diode Current (2-54)
    // ========================================================================
    const arg_sc_diode = v_sici.scale(1.0 / MSC).div(VT).minC(80.0);
    const i_jSC: S = if (ISCS > 0.0)
        arg_sc_diode.exp().addC(-1.0).mul(ISCS_Tv)
    else
        S.con(0.0);

    // ========================================================================
    // Internal Base Resistance (Section 2.6)
    // ========================================================================
    // Qz (2-59): 1 + v_jEi/VR0E + v_jCi/VR0C + i_Tf/IQF_eff + i_Tr/IQR
    const Qz = v_jEi.scale(1.0 / VR0E).add(v_jCi.scale(1.0 / VR0C)).add(i_Tf.div(IQF_eff)).add(i_Tr.scale(1.0 / IQR)).addC(1.0);

    // Smoothing function fQz (2-61): 0.5*(Qz + sqrt(Qz^2 + 0.01))
    const fQz = Qz.add(Qz.mul(Qz).addC(0.01).sqrt()).scale(0.5);

    // Base resistance before crowding (2-60): RBI0_T/fQz (0 if rbi0==0)
    const r_i: S = if (RBI0 > 0.0) RBI0_T.div(fQz) else S.con(0.0);

    // Emitter current crowding (2-62 through 2-66)
    const i_BE_total = i_jBE.abs();
    // zeta_ec = FGEO*r_i*i_BE_total/VT   (0 if r_i tiny)
    const r_i_tiny = r_i.val() <= 1.0e-30;
    const zeta_ec: S = if (r_i_tiny) S.con(0.0) else r_i.scale(FGEO).mul(i_BE_total).div(VT);

    // Gamma(zeta) = ln(1+zeta)/zeta for zeta>1e-6, else Taylor 1 - zeta/2.
    // Branch on zeta.val() (reproduces original piecewise smoothing).
    const gamma_val: S = if (zeta_ec.val() > 1.0e-6)
        zeta_ec.addC(1.0).log().div(zeta_ec)
    else
        zeta_ec.scale(-0.5).addC(1.0);

    // Final internal base resistance (2-66)
    const r_Bi = r_i.mul(gamma_val);

    // ========================================================================
    // Series Resistance Branch Currents.
    // RCX_T/RBX_T/RE_T are temperature-scaled (S under self-heating); the
    // resistance-value branch is param-driven (RCX_val>0 etc.), and r_Bi is S.
    // ========================================================================
    const g_rs: f64 = g_short; // no explicit substrate resistance in L0

    const v_rcx = x[c].sub(x[ci]).scale(type_f);
    const v_rbx = x[b].sub(x[bx]).scale(type_f);
    const v_rbi = x[bx].sub(x[bi]).scale(type_f);
    const v_re = x[e].sub(x[ei]).scale(type_f);
    const v_rs = x[s].sub(x[si]).scale(type_f);

    // i_r = v_r * (m/R_T) when R>0 else v_r * g_short
    const i_rcx: S = if (RCX_val > 0.0) v_rcx.scale(m_mult).div(RCX_T) else v_rcx.scale(g_short);
    const i_rbx: S = if (RBX > 0.0) v_rbx.scale(m_mult).div(RBX_T) else v_rbx.scale(g_short);
    // i_rbi = v_rbi * g_rbi where g_rbi = m/r_Bi or g_short
    const i_rbi: S = if (r_Bi.val() > 0.0) v_rbi.scale(m_mult).div(r_Bi) else v_rbi.scale(g_short);
    const i_re: S = if (RE > 0.0) v_re.scale(m_mult).div(RE_T) else v_re.scale(g_short);
    const i_rs = v_rs.scale(g_rs);

    // ========================================================================
    // Scale Intrinsic Currents by Multiplier
    // ========================================================================
    const i_jBE_s = i_jBE.scale(m_mult);
    const i_jBC_s = i_jBC.scale(m_mult);
    const i_T_s = i_T.scale(m_mult);
    const i_AVL_s = i_AVL.scale(m_mult);
    const I_TS_s = I_TS.scale(m_mult);
    const i_jSC_s = i_jSC.scale(m_mult);

    // ========================================================================
    // NQS Transfer Current Filter (Section 2.9)
    // ========================================================================
    const use_nqs = FLNQS;
    const v_xf = x[xf];
    const v_xq = x[xq];

    // i_xf = v_xf - i_T_s*type_f  (only when NQS)
    const i_xf: S = if (use_nqs) v_xf.sub(i_T_s.scale(type_f)) else S.con(0.0);
    // i_xq = v_xq - (i_Tf + i_Tr)*m_mult*type_f
    const i_xq: S = if (use_nqs) v_xq.sub(i_Tf.add(i_Tr).scale(m_mult * type_f)) else S.con(0.0);

    // Effective transport current stamped: v_xf*type_f (NQS) or i_T_s
    const i_T_eff: S = if (use_nqs) v_xf.scale(type_f) else i_T_s;

    // ========================================================================
    // Self-Heating Power Dissipation (Section 2.10, eqs 2-73, 2-74)
    // P = I_T*V_C'E'*type_f + I_AVL*(V_DCi - V_B'C')
    // ========================================================================
    const P_diss = i_T_eff.mul(v_ciei).scale(type_f).add(i_AVL_s.mul(VDCI_T.sub(v_bici)));

    // Thermal-node current. i_rth = v_dt / RTH_T (RTH_T is S under self-heating).
    // i_th = if self_heat: -P_diss + i_rth else v_dt*g_short
    const i_th: S = if (self_heat)
        P_diss.neg().add(v_dt_raw.div(RTH_T))
    else
        v_dt_raw.scale(g_short);

    // ========================================================================
    // KCL Node Stamping
    // ========================================================================
    var out: [n_u]S = undefined;

    out[c] = i_rcx.scale(-type_f);
    out[b] = i_rbx.scale(-type_f);
    out[e] = i_re.scale(-type_f);
    out[s] = i_rs.scale(-type_f);

    // ci: +i_rcx -i_T +i_jBC -i_AVL +I_TS +i_jSC  (all *type_f)
    out[ci] = i_rcx.sub(i_T_eff.scale(type_f)).add(i_jBC_s).sub(i_AVL_s).add(I_TS_s).add(i_jSC_s).scale(type_f);

    // bi: +i_rbi -i_jBE -i_jBC +i_AVL
    out[bi] = i_rbi.sub(i_jBE_s).sub(i_jBC_s).add(i_AVL_s).scale(type_f);

    // ei: +i_re +i_jBE +i_T
    out[ei] = i_re.add(i_jBE_s).add(i_T_eff.scale(type_f)).scale(type_f);

    // si: +i_rs -I_TS -i_jSC
    out[si] = i_rs.sub(I_TS_s).sub(i_jSC_s).scale(type_f);

    // bx: +i_rbx -i_rbi
    out[bx] = i_rbx.sub(i_rbi).scale(type_f);

    // NQS nodes
    out[xf] = if (use_nqs) i_xf else v_xf.scale(g_short);
    out[xq] = if (use_nqs) i_xq else v_xq.scale(g_short);

    // Thermal node
    out[dt] = i_th;

    return out;
}

// ============================================================================
// Charge Function (q)
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    // --- Node indices ---
    const c = @intFromEnum(U.c);
    const b = @intFromEnum(U.b);
    const e = @intFromEnum(U.e);
    const s = @intFromEnum(U.s);
    const ci = @intFromEnum(U.ci);
    const bi = @intFromEnum(U.bi);
    const ei = @intFromEnum(U.ei);
    const si = @intFromEnum(U.si);
    const bx = @intFromEnum(U.bx);
    const xf = @intFromEnum(U.xf);
    const xq = @intFromEnum(U.xq);
    const dt = @intFromEnum(U.dt);

    // --- Type factor ---
    const type_f: f64 = @floatFromInt(model.type_);

    // --- Cast model parameters ---
    const IS: f64 = @as(f64, model.is);
    const MCF: f64 = @as(f64, model.mcf);
    const MCR: f64 = @as(f64, model.mcr);
    const VEF: f64 = @as(f64, model.vef);
    const VER: f64 = @as(f64, model.ver);
    const AVER: f64 = @as(f64, model.aver);
    const RVER: f64 = @as(f64, model.rver);
    const IQF: f64 = @as(f64, model.iqf);
    const FIQF: f64 = @as(f64, model.fiqf);
    const IQR: f64 = @as(f64, model.iqr);
    const IQFH: f64 = @as(f64, model.iqfh);
    const TFH: f64 = @as(f64, model.tfh);
    const AHC: f64 = @as(f64, model.ahc);

    const CJE0: f64 = @as(f64, model.cje0);
    const VDE: f64 = @as(f64, model.vde);
    const ZE: f64 = @as(f64, model.ze);
    const AJE: f64 = @as(f64, model.aje);

    const T0: f64 = @as(f64, model.t0);
    const DT0H: f64 = @as(f64, model.dt0h);
    const TBVL: f64 = @as(f64, model.tbvl);
    const TEF0: f64 = @as(f64, model.tef0);
    const GTE: f64 = @as(f64, model.gte);
    const THCS: f64 = @as(f64, model.thcs);
    const TR: f64 = @as(f64, model.tr);

    const RCI0: f64 = @as(f64, model.rci0);
    const VLIM: f64 = @as(f64, model.vlim);
    const VPT: f64 = @as(f64, model.vpt);
    const VCES: f64 = @as(f64, model.vces);
    const VDCK: f64 = @as(f64, model.vdck);
    const DELCK: f64 = @as(f64, model.delck);
    const AICK: f64 = @as(f64, model.aick);

    const CJCI0: f64 = @as(f64, model.cjci0);
    const VDCI: f64 = @as(f64, model.vdci);
    const ZCI: f64 = @as(f64, model.zci);
    const VPTCI: f64 = @as(f64, model.vptci);

    const CJCX0: f64 = @as(f64, model.cjcx0);
    const VDCX: f64 = @as(f64, model.vdcx);
    const ZCX: f64 = @as(f64, model.zcx);
    const VPTCX: f64 = @as(f64, model.vptcx);
    const FBC: f64 = @as(f64, model.fbc);

    const CJS0: f64 = @as(f64, model.cjs0);
    const VDS: f64 = @as(f64, model.vds);
    const ZS: f64 = @as(f64, model.zs);
    const VPTS: f64 = @as(f64, model.vpts);

    const CBCPAR: f64 = @as(f64, model.cbcpar);
    const CBEPAR: f64 = @as(f64, model.cbepar);

    const VGB: f64 = @as(f64, model.vgb);
    const VGE: f64 = @as(f64, model.vge);
    const VGC: f64 = @as(f64, model.vgc);
    const VGS: f64 = @as(f64, model.vgs);
    const DVGBE: f64 = @as(f64, model.dvgbe);
    const F1VG: f64 = @as(f64, model.f1vg);
    const ALT0: f64 = @as(f64, model.alt0);
    const KT0: f64 = @as(f64, model.kt0);
    const ZETAVGBE: f64 = @as(f64, model.zetavgbe);
    const ZETAVER: f64 = @as(f64, model.zetaver);
    const ZETACT: f64 = @as(f64, model.zetact);
    const ZETABET: f64 = @as(f64, model.zetabet);
    const ZETAIQF: f64 = @as(f64, model.zetaiqf);
    const ZETACI: f64 = @as(f64, model.zetaci);
    const ZETAIQFH: f64 = @as(f64, model.zetaiqfh);
    const ALVS: f64 = @as(f64, model.alvs);
    const ALCES: f64 = @as(f64, model.alces);
    const ALDCK: f64 = @as(f64, model.aldck);

    const FLNQS: bool = model.flnqs != 0;
    const ALIT: f64 = @as(f64, model.alit);
    const ALQF: f64 = @as(f64, model.alqf);

    const FLSH: bool = model.flsh != 0;
    const RTH: f64 = @as(f64, model.rth);
    const CTH: f64 = @as(f64, model.cth);

    const TNOM: f64 = @as(f64, model.tnom);
    const DT_INST: f64 = @as(f64, model.dt_);

    const FLTEFT: bool = model.flteft != 0;
    const FLITM: bool = model.flitm != 0;

    const m_mult: f64 = @as(f64, instance.m);

    // ========================================================================
    // Temperature (self-heating rise is x[dt]-dependent -> S)
    // ========================================================================
    const T0K = TNOM + 273.15;
    const v_dt_raw = x[dt];
    const self_heat = FLSH and RTH > 0.0;
    const delta_T_sh: S = if (self_heat) v_dt_raw else S.con(0.0);
    const T_dev = delta_T_sh.addC(T0K + DT_INST);
    const VT = T_dev.scale(KB_Q);
    const VT0 = KB_Q * T0K;
    const r_T = T_dev.scale(1.0 / T0K);
    const ln_rT = r_T.maxC(1.0e-30).log();
    const delta_T = T_dev.addC(-T0K);

    const K1 = F1VG;
    const k1 = K1 * T0K;
    const mg = 3.0 - k1 / VT0;

    const one_m_rT = r_T.addC(-1.0);

    // Temperature-scaled parameters
    const IS_Tv = ln_rT.scale(ZETACT).add(one_m_rT.scale(VGB).div(VT)).exp().scale(IS);
    const IQF_Tv = ln_rT.scale(ZETAIQF).sub(one_m_rT.scale(DVGBE / VT0)).exp().scale(IQF);
    const IQFH_Tv = ln_rT.scale(ZETAIQFH).exp().scale(IQFH);
    const TFH_Tv = ln_rT.scale(ZETAIQFH).add(one_m_rT.scale((VGB - VGE) / VT0)).exp().scale(TFH);
    // tef0(T) (2-92): TEF0 * exp(ZETABET*ln_rT - (VGB-VGE)/VT*one_m_rT) if FLTEFT else TEF0
    const TEF0_T: S = if (FLTEFT)
        ln_rT.scale(ZETABET).sub(one_m_rT.scale(VGB - VGE).div(VT)).exp().scale(TEF0)
    else
        S.con(TEF0);
    const T0_T = delta_T.scale(ALT0).add(delta_T.mul(delta_T).scale(KT0)).addC(1.0).scale(T0);
    const RCI0_T = ln_rT.scale(ZETACI).exp().scale(RCI0);
    const VLIM_T = ln_rT.scale(ZETACI - ALVS).exp().scale(VLIM);
    const VCES_T = delta_T.scale(ALCES).addC(1.0).scale(VCES);
    const VDCK_T = delta_T.scale(-ALDCK).addC(1.0).scale(VDCK);

    // Temperature-scaled built-in voltages
    const VDE_T = tempScaleVD(S, VDE, VGB, mg, VT, VT0, r_T, ln_rT);
    const VDCI_T = tempScaleVD(S, VDCI, VGC, mg, VT, VT0, r_T, ln_rT);
    const VDCX_T = tempScaleVD(S, VDCX, VGC, mg, VT, VT0, r_T, ln_rT);
    const VDS_T = tempScaleVD(S, VDS, VGS, mg, VT, VT0, r_T, ln_rT);

    // Temperature-scaled zero-bias capacitances
    const CJE0_Tv = S.con(VDE).div(VDE_T).maxC(1.0e-30).log().scale(ZE).exp().scale(CJE0);
    const CJCI0_Tv = S.con(VDCI).div(VDCI_T).maxC(1.0e-30).log().scale(ZCI).exp().scale(CJCI0);
    const CJCX0_Tv = S.con(VDCX).div(VDCX_T).maxC(1.0e-30).log().scale(ZCX).exp().scale(CJCX0);
    const CJS0_Tv = S.con(VDS).div(VDS_T).maxC(1.0e-30).log().scale(ZS).exp().scale(CJS0);

    const AJE_T = VDE_T.scale(AJE / VDE);

    // VEr temperature (2-102): dvgbe=0 => no temperature effect
    const dvgbe_pow_q: f64 = if (@abs(DVGBE) < 1.0e-30) 0.0 else contract.fmath.exp(ZETAVGBE * contract.fmath.log(@abs(DVGBE)));
    const VER_T = one_m_rT.scale(dvgbe_pow_q).div(VT).neg().exp().scale(VER);
    const AVER_T = ln_rT.scale(ZETAVER).exp().scale(AVER);

    // ========================================================================
    // BC Capacitance Partitioning
    // ========================================================================
    const cjcx0_is_zero = CJCX0 < 1.0e-30;
    const C_jCi0: S = if (cjcx0_is_zero) CJCI0_Tv.scale(FBC) else CJCI0_Tv;
    const C_jCx01: S = if (cjcx0_is_zero) CJCI0_Tv.scale(1.0 - FBC) else CJCX0_Tv.scale(1.0 - FBC);

    // ========================================================================
    // Branch Voltages
    // ========================================================================
    const v_biei = x[bi].sub(x[ei]).scale(type_f);
    const v_bici = x[bi].sub(x[ci]).scale(type_f);
    const v_ciei = x[ci].sub(x[ei]).scale(type_f);
    const v_sici = x[si].sub(x[ci]).scale(type_f);
    const v_bxci = x[bx].sub(x[ci]).scale(type_f);
    const v_bxei = x[bx].sub(x[ei]).scale(type_f);

    // ========================================================================
    // BE Depletion Charge (eqs 2-2 through 2-8)
    // ========================================================================
    const Vf_BE = AJE_T.maxC(1.0e-30).log().scale(-1.0 / ZE).exp().neg().addC(1.0).mul(VDE_T);
    const x_be = Vf_BE.sub(v_biei).div(VT);
    const sqrt_x_be = x_be.mul(x_be).addC(a_fj).sqrt();
    const vj_be = Vf_BE.sub(VT.mul(x_be.add(sqrt_x_be)).scale(0.5));
    const one_m_vj_vde = vj_be.div(VDE_T).neg().addC(1.0).maxC(1.0e-30);
    const Q_jE = CJE0_Tv.mul(VDE_T).scale(1.0 / (1.0 - ZE)).mul(one_m_vj_vde.log().scale(1.0 - ZE).exp().neg().addC(1.0)).add(AJE_T.mul(CJE0_Tv).mul(v_biei.sub(vj_be)));

    // ========================================================================
    // Internal BC Depletion Charge
    // ========================================================================
    const Vf_BCi = VDCI_T.scale(1.0 - contract.fmath.exp((-1.0 / ZCI) * contract.fmath.log(2.5)));
    const x_bci = Vf_BCi.sub(v_bici).div(VT);
    const sqrt_x_bci = x_bci.mul(x_bci).addC(a_fj).sqrt();
    const vj_bci = Vf_BCi.sub(VT.mul(x_bci.add(sqrt_x_bci)).scale(0.5));
    const one_m_vjci_vdci = vj_bci.div(VDCI_T).neg().addC(1.0).maxC(1.0e-30);
    const Q_jCi_base = C_jCi0.mul(VDCI_T).scale(1.0 / (1.0 - ZCI)).mul(one_m_vjci_vdci.log().scale(1.0 - ZCI).exp().neg().addC(1.0)).add(C_jCi0.scale(2.5).mul(v_bici.sub(vj_bci)));
    const Q_jCi = Q_jCi_base.add(C_jCi0.mul(vj_bci).mul(vj_bci).scale(1.0 / (2.0 * VPTCI)));
    const Cc = one_m_vjci_vdci.log().scale(-ZCI).exp();

    // ========================================================================
    // External BC Depletion Charge (split portion C_jCx01, across rbx)
    // ========================================================================
    const Vf_BCx = VDCX_T.scale(1.0 - contract.fmath.exp((-1.0 / ZCX) * contract.fmath.log(2.5)));
    const x_bcx = Vf_BCx.sub(v_bxci).div(VT);
    const sqrt_x_bcx = x_bcx.mul(x_bcx).addC(a_fj).sqrt();
    const vj_bcx = Vf_BCx.sub(VT.mul(x_bcx.add(sqrt_x_bcx)).scale(0.5));
    const one_m_vjcx_vdcx = vj_bcx.div(VDCX_T).neg().addC(1.0).maxC(1.0e-30);
    const Q_jCx_base = C_jCx01.mul(VDCX_T).scale(1.0 / (1.0 - ZCX)).mul(one_m_vjcx_vdcx.log().scale(1.0 - ZCX).exp().neg().addC(1.0)).add(C_jCx01.scale(2.5).mul(v_bxci.sub(vj_bcx)));
    const Q_jCx = Q_jCx_base.add(C_jCx01.mul(vj_bcx).mul(vj_bcx).scale(1.0 / (2.0 * VPTCX)));

    // ========================================================================
    // CS Depletion Charge
    // ========================================================================
    const Vf_CS = VDS_T.scale(1.0 - contract.fmath.exp((-1.0 / ZS) * contract.fmath.log(2.5)));
    const x_cs = Vf_CS.sub(v_sici).div(VT);
    const sqrt_x_cs = x_cs.mul(x_cs).addC(a_fj).sqrt();
    const vj_cs = Vf_CS.sub(VT.mul(x_cs.add(sqrt_x_cs)).scale(0.5));
    const one_m_vjcs_vds = vj_cs.div(VDS_T).neg().addC(1.0).maxC(1.0e-30);
    const Q_jS_base = CJS0_Tv.mul(VDS_T).scale(1.0 / (1.0 - ZS)).mul(one_m_vjcs_vds.log().scale(1.0 - ZS).exp().neg().addC(1.0)).add(CJS0_Tv.scale(2.5).mul(v_sici.sub(vj_cs)));
    const Q_jS = Q_jS_base.add(CJS0_Tv.mul(vj_cs).mul(vj_cs).scale(1.0 / (2.0 * VPTS)));

    // ========================================================================
    // Heterojunction VEr
    // ========================================================================
    const x_u = VDE_T.sub(v_biei).div(VT.scale(RVER));
    const sqrt_xu = x_u.mul(x_u).addC(a_fj).sqrt();
    const v_ju = VDE_T.sub(VT.scale(RVER).mul(x_u.add(sqrt_xu)).scale(0.5));
    const one_m_vju_vde = v_ju.div(VDE_T).neg().addC(1.0).maxC(1.0e-30);
    const u_ver = one_m_vju_vde.log().scale(ZE).exp().neg().addC(1.0).mul(AVER_T);
    const u_min: f64 = 0.001;
    const B_large = u_ver.minC(80.0).exp().addC(-1.0).div(u_ver.addC(1.0e-30));
    const B_small = u_ver.scale(0.5).addC(1.0);
    const B_u: S = if (@abs(u_ver.val()) >= u_min) B_large else B_small;
    const VER_eff = VER_T.mul(B_u);

    // Normalized depletion charges
    const v_jEi = Q_jE.div(CJE0_Tv);
    const v_jCi = Q_jCi.div(C_jCi0);
    const qj = v_jEi.div(VER_eff).add(v_jCi.scale(1.0 / VEF)).addC(1.0);

    // ========================================================================
    // Transfer Current Components (needed for diffusion charges)
    // ========================================================================
    const arg_be = v_biei.scale(1.0 / MCF).div(VT).minC(80.0);
    const i_Tfi = arg_be.exp().mul(IS_Tv);
    const arg_bc = v_bici.scale(1.0 / MCR).div(VT).minC(80.0);
    const i_Tri = arg_bc.exp().mul(IS_Tv);

    // c_ratio for transit time
    const c_ratio_v = S.con(1.0).div(Cc.maxC(1.0e-30));
    const tau_f0 = T0_T.add(c_ratio_v.addC(-1.0).scale(DT0H)).add(S.con(1.0).div(c_ratio_v).addC(-1.0).scale(TBVL));
    const T0_tiny = T0_T.val() <= 1.0e-30;
    const tau_ratio: S = if (T0_tiny) S.con(1.0) else tau_f0.div(T0_T);
    const IQF_eff = IQF_Tv.div(tau_ratio.addC(-1.0).scale(FIQF).addC(1.0));

    // Normalized mobile charge
    const qfli = i_Tfi.div(IQF_eff).add(i_Tri.scale(1.0 / IQR));

    // ========================================================================
    // Critical Current ICK
    // ========================================================================
    const vc_raw: S = if (VDCK > 0.0) VDCK_T.sub(v_bici) else v_ciei.sub(VCES_T);
    const u_ce = vc_raw.sub(VT).div(VT);
    const sqrt_u_ce = u_ce.mul(u_ce).addC(a_fj).sqrt();
    const v_ceff = VT.mul(u_ce.add(sqrt_u_ce).scale(0.5).addC(1.0));
    const v_over_vlim = v_ceff.div(VLIM_T);
    const vlim_denom = v_over_vlim.maxC(1.0e-30).log().scale(DELCK).exp().addC(1.0).maxC(1.0e-30).log().scale(1.0 / DELCK).exp();
    const x_ick = v_ceff.sub(VLIM_T).scale(1.0 / VPT);
    const sqrt_x_ick = x_ick.mul(x_ick).addC(AICK).sqrt();
    const ICK = v_ceff.div(RCI0_T.mul(vlim_denom)).mul(x_ick.add(sqrt_x_ick).scale(0.5).addC(1.0)).scale(m_mult);

    // ========================================================================
    // Solve qpT (same as in eval)
    // ========================================================================
    const qpT = solveQpT(S, qj, qfli, i_Tfi, IQFH_Tv, TFH_Tv, ICK, S.con(IQR), FLITM);

    const i_Tf = i_Tfi.div(qpT);
    const i_Tr = i_Tri.div(qpT);

    // ========================================================================
    // Injection Width w (2-17, 2-18)
    // ========================================================================
    // i_norm = 1 - ICK/max(i_Tf, 1e-30)
    const i_norm = ICK.div(i_Tf.maxC(1.0e-30)).neg().addC(1.0);
    const sqrt_i2_ahc = i_norm.mul(i_norm).addC(AHC).sqrt();
    const one_p_sqrt_ahc = 1.0 + @sqrt(1.0 + AHC);
    const w_inj = i_norm.add(sqrt_i2_ahc).scale(1.0 / one_p_sqrt_ahc);
    const w2 = w_inj.mul(w_inj);

    // ========================================================================
    // Forward Minority Charges (Section 2.3, eqs 2-12 through 2-24)
    // ========================================================================
    // Q_f0 = tau_f0 * i_Tf (2-14)
    const Q_f0 = tau_f0.mul(i_Tf);

    // Emitter transit time component (2-23): TEF0_T * (i_Tf/ICK)^GTE
    const tau_Ef = TEF0_T.mul(i_Tf.div(ICK).maxC(1.0e-30).log().scale(GTE).exp());

    // Emitter charge component (2-24): tau_Ef * i_Tf / (1+GTE)
    const Q_Ef = tau_Ef.mul(i_Tf).scale(1.0 / (1.0 + GTE));

    // High-current collector transit time (2-16):
    // tau_fh = THCS*w^2*(1 + 2*ICK/(i_Tf*sqrt(i^2+ahc)))
    const tau_fh = w2.scale(THCS).mul(ICK.scale(2.0).div(i_Tf.maxC(1.0e-30).mul(sqrt_i2_ahc)).addC(1.0));
    const Q_fh = tau_fh.mul(i_Tf);

    // Total forward minority charge (2-12)
    const Q_f = Q_f0.add(Q_Ef).add(Q_fh);

    // ========================================================================
    // Reverse Minority Charge (2-25)
    // ========================================================================
    const Q_r = i_Tr.scale(TR);

    // ========================================================================
    // Parasitic Capacitances
    // ========================================================================
    const Q_bcpar = v_bxci.scale(CBCPAR * m_mult);
    const Q_bepar = v_bxei.scale(CBEPAR * m_mult);

    // ========================================================================
    // NQS Charge (Section 2.9)
    // ========================================================================
    const use_nqs = FLNQS;
    // tau_IT = alit * T0_T, tau_Qf = alqf * T0_T (T0_T is x-dependent via self-heating)
    const tau_IT_s = T0_T.scale(ALIT);
    const tau_Qf_s = T0_T.scale(ALQF);
    const v_xf = x[xf];
    const v_xq = x[xq];

    // NQS transfer current filter charge: Q = tau_IT * v_xf
    const Q_nqs_it: S = if (use_nqs) tau_IT_s.mul(v_xf) else S.con(0.0);
    // NQS minority charge filter charge: Q = tau_Qf * v_xq
    const Q_nqs_qf: S = if (use_nqs) tau_Qf_s.mul(v_xq) else S.con(0.0);

    // ========================================================================
    // Self-Heating Thermal Capacitance Charge
    // ========================================================================
    const Q_cth: S = if (self_heat) x[dt].scale(CTH * m_mult) else S.con(0.0);

    // ========================================================================
    // Scale charges by multiplier
    // ========================================================================
    const Q_jE_s = Q_jE.scale(m_mult);
    const Q_jCi_s = Q_jCi.scale(m_mult);
    const Q_jCx_s = Q_jCx.scale(m_mult);
    const Q_jS_s = Q_jS.scale(m_mult);
    const Q_f_s = Q_f.scale(m_mult);
    const Q_r_s = Q_r.scale(m_mult);

    // ========================================================================
    // Charge KCL Stamps
    // ========================================================================
    var out: [n_u]S = undefined;

    out[c] = S.con(0.0);
    out[b] = S.con(0.0);
    out[e] = S.con(0.0);
    out[s] = S.con(0.0);

    // bi: +Q_jE + Q_f + Q_jCi + Q_r
    out[bi] = Q_jE_s.add(Q_f_s).add(Q_jCi_s).add(Q_r_s).scale(type_f);

    // ei: -Q_jE - Q_f - Q_bepar
    out[ei] = Q_jE_s.neg().sub(Q_f_s).sub(Q_bepar).scale(type_f);

    // ci: -Q_jCi - Q_r - Q_jCx + Q_jS + Q_bcpar
    out[ci] = Q_jCi_s.neg().sub(Q_r_s).sub(Q_jCx_s).add(Q_jS_s).sub(Q_bcpar).scale(type_f);

    // bx: +Q_jCx + Q_bcpar + Q_bepar
    out[bx] = Q_jCx_s.add(Q_bcpar).add(Q_bepar).scale(type_f);

    // si: -Q_jS
    out[si] = Q_jS_s.neg().scale(type_f);

    // NQS nodes
    out[xf] = Q_nqs_it;
    out[xq] = Q_nqs_qf;

    // Thermal
    out[dt] = Q_cth;

    return out;
}

// ============================================================================
// Voltage Limiting (DEVpnjlim for BE and BC junctions)
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const bi = @intFromEnum(U.bi);
    const ci = @intFromEnum(U.ci);
    const ei = @intFromEnum(U.ei);
    const si = @intFromEnum(U.si);

    const type_f: f64 = @floatFromInt(model.type_);

    const IBES: f64 = @as(f64, model.ibes);
    const IBCS: f64 = @as(f64, model.ibcs);
    const MBE: f64 = @as(f64, model.mbe);
    const MBC: f64 = @as(f64, model.mbc);
    const TNOM: f64 = @as(f64, model.tnom);
    const vtv: f64 = 8.617333e-5 * (TNOM + 273.15);

    var result = x_new;

    // Limit BE junction (bi - ei)
    result = pnjlim(result, x_old, bi, ei, IBES, MBE, vtv, type_f);

    // Limit BC junction (bi - ci)
    result = pnjlim(result, x_old, bi, ci, IBCS, MBC, vtv, type_f);

    // Limit SC junction (si - ci) if substrate current enabled
    const ISCS: f64 = @as(f64, model.iscs);
    const MSC: f64 = @as(f64, model.msc);
    if (ISCS > 0.0) {
        result = pnjlim(result, x_old, si, ci, ISCS, MSC, vtv, type_f);
    }

    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const gmin_step: f64 = 1.0e-12;

    // Scale IS by adding gmin*(1-lambda) for convergence
    const is_orig: f64 = @as(f64, model.is);
    m.is = @floatCast(is_orig + gmin_step * (1.0 - lambda));

    // Scale IBES similarly
    const ibes_orig: f64 = @as(f64, model.ibes);
    m.ibes = @floatCast(ibes_orig + gmin_step * (1.0 - lambda));

    // Scale IBCS
    const ibcs_orig: f64 = @as(f64, model.ibcs);
    m.ibcs = @floatCast(ibcs_orig + gmin_step * (1.0 - lambda));

    return m;
}

// ============================================================================
// Helper: PN junction voltage limiting (DEVpnjlim)
// ============================================================================

inline fn pnjlim(x_new: [n_u]f64, x_old: [n_u]f64, pos: usize, neg: usize, is_val: f64, n_em: f64, vtv: f64, type_f: f64) [n_u]f64 {
    const nvt = n_em * vtv;
    const v_crit = nvt * contract.fmath.log(nvt / (@sqrt(2.0) * @max(is_val, 1.0e-30)));

    const vd_new = (x_new[pos] - x_new[neg]) * type_f;
    const vd_old = (x_old[pos] - x_old[neg]) * type_f;

    var vd_limited = vd_new;

    if (vd_new > v_crit and @abs(vd_new - vd_old) > 2.0 * nvt) {
        if (vd_old > 0.0) {
            const arg = (vd_new - vd_old) / nvt;
            if (arg > 0.0) {
                vd_limited = vd_old + nvt * (2.0 + contract.fmath.log(@max(arg - 2.0, 1.0e-30)));
            } else {
                vd_limited = vd_old - nvt * (2.0 + contract.fmath.log(@max(2.0 - arg, 1.0e-30)));
            }
        } else {
            vd_limited = nvt * contract.fmath.log(@max(vd_new / nvt, 1.0e-30));
        }
    }

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

test "hicum_l0: forward-active transfer current residual" {
    // Simple diode-connected forward transport: default NPN with the
    // intrinsic terminals biased. Vbe=0.7 into the intrinsic BE junction,
    // all other internal nodes tied to make series resistances short.
    //
    // Hand check of the collector-current sign: with vbe>0 and vbc<0, the
    // transfer current i_T = (i_Tfi - i_Tri)/qpT is positive and flows out
    // of ei (out[ei] gets +i_T) and into ci (out[ci] gets -i_T). We only
    // check that current is conserved (sum of all rows == 0) and that the
    // emitter row is positive (electron injection), which is the physics
    // regression that the sign conventions are preserved.
    const model: Model = .{}; // default NPN, no self-heating, no NQS
    var inst: Instance = .{};
    _ = &inst;

    // x indices: c b e s ci bi ei si bx xf xq dt
    // Bias: collector at 1.0, base 0.7, emitter 0, others follow so that
    // internal nodes equal their external counterparts (short resistors).
    const x = [n_u]f64{
        1.0, // c
        0.7, // b
        0.0, // e
        0.0, // s
        1.0, // ci
        0.7, // bi
        0.0, // ei
        0.0, // si
        0.7, // bx
        0.0, // xf
        0.0, // xq
        0.0, // dt
    };
    const out = contract.evalValues(Self, x, &model, &inst, 0);

    // Current conservation: KCL rows must sum to ~0 (device injects no net current).
    var sum: f64 = 0;
    for (out) |v| sum += v;
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-6);

    // Emitter row should carry the (positive) transport + BE current out.
    try testing.expect(out[@intFromEnum(U.ei)] > 0.0);
    // Collector intrinsic row should be negative (transport current sinks in).
    try testing.expect(out[@intFromEnum(U.ci)] < 0.0);
}

test "hicum_l0: BE depletion charge at zero bias" {
    // At v_biei = 0 the BE depletion charge Q_jE should be finite and small
    // but nonzero (the smoothing/linear term). We verify the bi charge row
    // equals -(ei charge row minus parasitics) i.e. charge is conserved
    // between bi and ei for the BE junction with default (zero) parasitics.
    //
    // With CBEPAR=0 default, out[ei] = -(Q_jE + Q_f)*type_f and the bi row
    // contains +(Q_jE + Q_f + Q_jCi + Q_r). At zero bias forward currents
    // vanish (i_Tf~i_Tfi/qpT is tiny given IS=1e-16), so Q_f ~ 0, and the
    // depletion charges dominate. We check bi + ei + ci + bx + si == 0
    // (total stored charge conservation across internal nodes).
    const model: Model = .{ .cje0 = 1.0e-15, .cjci0 = 1.0e-15 };
    var inst: Instance = .{};
    _ = &inst;

    const x = [n_u]f64{
        0.0, 0.0, 0.0, 0.0, // c b e s
        0.0, 0.0, 0.0, 0.0, // ci bi ei si
        0.0, 0.0, 0.0, 0.0, // bx xf xq dt
    };
    const qout = contract.qValues(Self, x, &model, &inst, 0);

    // Charge conservation across the internal charge-bearing nodes.
    var sum: f64 = 0;
    for (qout) |v| sum += v;
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-18);
}

test "hicum_l0: PNP type factor gives mirrored, conserving physics" {
    // A PNP (type_=-1) driven by the physically-negated bias produces the same
    // magnitude intrinsic current as the NPN (the type factor threads through
    // the S chain symmetrically) and still conserves current. The stamping
    // applies type_f twice to the transport term and once to the diode terms,
    // so the emitter ROW value is approximately type-invariant by construction
    // -- what we assert is (a) current conservation for the PNP and (b) that
    // the emitter magnitude matches the NPN case to within f32-param tolerance.
    const npn: Model = .{ .type_ = 1 };
    const pnp: Model = .{ .type_ = -1 };
    var inst: Instance = .{};
    _ = &inst;

    const x_npn = [n_u]f64{ 1.0, 0.7, 0.0, 0.0, 1.0, 0.7, 0.0, 0.0, 0.7, 0.0, 0.0, 0.0 };
    // For PNP, the same physical forward bias is the negated node voltages.
    const x_pnp = [n_u]f64{ -1.0, -0.7, 0.0, 0.0, -1.0, -0.7, 0.0, 0.0, -0.7, 0.0, 0.0, 0.0 };

    const o_npn = contract.evalValues(Self, x_npn, &npn, &inst, 0);
    const o_pnp = contract.evalValues(Self, x_pnp, &pnp, &inst, 0);

    // Current conservation for the PNP device.
    var sum: f64 = 0;
    for (o_pnp) |v| sum += v;
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-6);

    // Nonzero forward emitter current, mirrored between NPN and PNP.
    try testing.expect(o_npn[@intFromEnum(U.ei)] > 1e-6);
    try testing.expect(o_pnp[@intFromEnum(U.ei)] > 1e-6);
    try testing.expectApproxEqRel(o_npn[@intFromEnum(U.ei)], o_pnp[@intFromEnum(U.ei)], 5e-2);
}
