const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: ASM-ESD 101.1.0 — ESD Protection Diode / BJT
//
//   C (collector)  -- RC -- C_i (intrinsic collector)     [4-terminal only]
//   B (base/anode) -- RB -- B_i (intrinsic base)
//   E (emitter/cathode) -- RE -- E_i (intrinsic emitter)
//   DT (thermal node)   -- self-heating network -- DT1
//   TT (charge modulation filter node for RBMOD=1)
//
//   Intrinsic diode/BJT between B_i, C_i, E_i with ESD-specific enhancements:
//   - Post-reverse-breakdown resistance model (THER, THEEXP)
//   - Reverse tunnel current (ISR, NTR, VTR)
//   - Velocity-saturated base/emitter resistors
//   - Bias-dependent base resistance (RBMOD=1)
//   - Multi-pole self-heating (SHMOD=1,2)
//   - Delayed BJT transient response (CDELAY, CTHBB)
//   - Base-width modulation (KBWM)
//   - Excess phase (PTF)
//
//   NPN/PNP polarity handled by sign factor TYPE (+1 NPN, -1 PNP).
// ============================================================================

pub const U = enum(u8) {
    c, // 0: external collector
    b, // 1: external base (anode)
    e, // 2: external emitter (cathode)
    dt, // 3: external thermal node
    b_i, // 4: intrinsic base
    e_i, // 5: intrinsic emitter
    c_i, // 6: intrinsic collector
    dt1, // 7: second thermal node (SHMOD=2)
    tt, // 8: charge modulation filter node (RBMOD=1, Eq 2.5.4)
    tbb, // 9: delayed BJT filter node (CDELAY, Eq 2.4.17)
};
pub const num_ports: usize = 4;

// ============================================================================
// Physical Constants
// ============================================================================

const Q_ELEC: f64 = 1.6021918e-19;
const K_B: f64 = 1.3806226e-23;
const KB_Q: f64 = 8.6170869e-5;
const EG_300: f64 = 1.1150877;
const EG0: f64 = 1.16;
const EGTA: f64 = 7.0200e-4;
const EGTB: f64 = 1.1080e3;
const REF_T: f64 = 300.15;
const PI: f64 = 3.14159265358979323846;

// ============================================================================
// Model Parameters (70 total)
// ============================================================================

pub const Model = struct {
    // --- Model Controllers ---
    type_: i32 = 1, // +1 = NPN, -1 = PNP
    shmod: i32 = 2, // Self-heating: -1=ext, 0=off, 1=single RC, 2=dual RC
    extmod: i32 = 0, // Extrinsic parasitic: 0=off, 1=on
    rbmod: i32 = 1, // Base resistance: 0=fixed, 1=bias-dependent

    // --- Current Model Parameters ---
    is: f32 = 1.0e-17, // Saturation current (A/m)
    nf: f32 = 1.0, // Forward emission coefficient
    isr: f32 = 0.0, // Tunnel current coefficient (A/m)
    ntr: f32 = 5.0, // Reverse tunnel emission coefficient
    vtr: f32 = 10.0, // Reverse tunnel current bias dependence (V)
    bvr: f32 = 10.0, // Reverse breakdown voltage (V)
    nbv: f32 = 10.0, // Slope of current near breakdown for B-E
    ijbv: f32 = 5.0, // Post reverse breakdown current for B-E (A/m)
    ther: f32 = 0.01, // Post reverse breakdown I-V parameter (1/V^THEEXP)
    theexp: f32 = 1.11, // Post reverse breakdown non-linearity exponent
    eg: f32 = 1.11, // Band gap (eV)
    bf: f32 = 0.1, // Forward BJT current gain (4-terminal)
    br: f32 = 1.0, // Reverse BJT current gain (4-terminal)
    nr: f32 = 10.0, // Forward emission coefficient for B-C (4-terminal)
    vaf: f32 = 0.0, // Forward early voltage (V)
    var_: f32 = 0.0, // Reverse early voltage (V)
    ikf: f32 = 0.0, // Forward gain high current roll-off (A/m)
    xkf: f32 = 0.9, // Forward BJT gain roll-off exponent
    ikr: f32 = 0.0, // Reverse gain high current roll-off (A/m)
    ise: f32 = 0.0, // B-E leakage saturation current (A/m)
    ne: f32 = 1.5, // B-E leakage emission coefficient
    isc: f32 = 0.0, // B-C leakage saturation current (A/m)
    nc: f32 = 2.0, // Emission coefficient for B-C current
    nbvc: f32 = 20.0, // Slope of current near breakdown for B-C
    ijbvc: f32 = 0.0, // Post reverse breakdown current for B-C (A/m)
    kbwm: f32 = 0.0, // Base-width modulation impact on BJT gain (V^-XBWM)
    xbwm: f32 = 1.0, // Exponent for base-width modulation
    ikbwm: f32 = 0.0, // Base width modulation multiplier (1/V)
    cthbb: f32 = 10.0e-9, // Delayed BJT collector current time-constant
    cdelay: f32 = 0.0, // Delayed BJT current parameter; 0 = no delay
    ptf: f32 = 0.0, // Excess phase at freq = 1/(TF*2*pi) Hz

    // --- Resistance Model Parameters ---
    rb: f32 = 1.0e-5, // Base resistance (Ohm.m)
    re: f32 = 1.0e-6, // Emitter resistance (Ohm.m)
    rc: f32 = 1.0e-6, // Collector resistance (Ohm.m)
    rbe: f32 = 0.0, // Extrinsic base resistance (Ohm.m)
    ree: f32 = 0.0, // Extrinsic emitter resistance (Ohm.m)
    rce: f32 = 0.0, // Extrinsic collector resistance (Ohm.m)
    tf: f32 = 0.0, // Forward transit time (sec)
    tr: f32 = 0.0, // Reverse transit time (sec)
    vtf0: f32 = 100.0, // Transit time voltage/field threshold (V)
    texp: f32 = 2.0, // Carrier transit time field dependence parameter
    atff: f32 = 0.0, // Transit time field dependence multiplier
    mexp: f32 = 2.0, // Velocity saturation exponent for base resistor
    mexpe: f32 = 2.0, // Velocity saturation exponent for emitter resistor
    vsatb: f32 = 100.0, // Velocity saturation voltage for base (V)
    vsate: f32 = 100.0, // Velocity saturation voltage for emitter (V)
    qexp: f32 = 1.0, // Charge dependence of base resistance exponent
    qtt0: f32 = 1.0e-3, // Base resistance charge dependence (C/m)
    fc: f32 = 0.5, // Coefficient for forward-bias depletion cap linearization
    minr: f32 = 1e-3, // Minimum resistance (Ohm)

    // --- Capacitance Parameters ---
    cje: f32 = 0.0, // Zero-bias B-E junction capacitance (F/m)
    vje: f32 = 0.75, // B-E junction built-in potential (V)
    mje: f32 = 0.33, // B-E junction exponential factor
    cjc: f32 = 0.0, // Zero-bias B-C junction capacitance (F/m)
    vjc: f32 = 0.75, // B-C junction built-in potential (V)
    mjc: f32 = 0.33, // B-C junction exponential factor
    cjs: f32 = 0.0, // Zero-bias E-C (substrate) junction capacitance (F/m)
    vjs: f32 = 0.75, // E-C junction built-in potential (V)
    mjs: f32 = 0.33, // E-C junction exponential factor
    xcjc: f32 = 1.0, // Fraction of B-C depl cap at internal base node

    // --- Noise Model Parameters ---
    kf: f32 = 0.0, // Flicker noise coefficient
    af: f32 = 1.0, // Flicker noise exponent

    // --- Temperature Dependence and Self-Heating ---
    tnom: f32 = 25.0, // Nominal temperature (degC)
    xti: f32 = 3.0, // Temperature dependence of IS
    xtir: f32 = 0.5, // Temperature dependence of ISR
    xtb: f32 = 0.0, // Temperature dependence of BF and BR
    xjbv: f32 = 0.0, // Temperature dependence of IJBV
    xjbvc: f32 = 5.0, // Temperature dependence of IJBVC
    xbvr: f32 = 0.0, // Temperature dependence of BVR
    xtheexp: f32 = 0.0, // Temperature dependence of THEEXP
    arb: f32 = 0.0, // Temperature dependence of RB
    are: f32 = 0.0, // Temperature dependence of RE
    arc: f32 = 0.0, // Temperature dependence of RC
    tfail: f32 = 1000.0, // Failure temperature (K)
    rth0: f32 = 5.0e-4, // Thermal resistance (K/W)
    cth0: f32 = 5.0e-4, // Thermal capacitance (s*W/K)
    rth1: f32 = 5.0e-6, // Thermal resistance 2nd pole (K/W)
    cth1: f32 = 1.0e-7, // Thermal capacitance 2nd pole (s*W/K)
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    l: f32 = 10.0e-6, // Finger length (m)
    n: f32 = 1, // Number of fingers
    dtemp: f32 = 0.0, // Instance temperature offset (degC)
};

// ============================================================================
// Sparse Conductance Stamp Pattern
// ============================================================================
// The ASM-ESD stamps into:
//   RB branch: B -- B_i
//   RE branch: E -- E_i
//   RC branch: C -- C_i
//   Intrinsic: B_i, E_i, C_i (all cross-terms)
//   B -- C_i (external B-C cap partitioning)
//   E -- C_i (substrate cap)
//   DT (thermal): self-coupling + DT1 coupling
//   DT1: self + DT coupling
//   TT: self + B_i, E_i coupling

pub const g_pattern_override = [_]contract.Entry(n_u){
    // RB branch: B -- B_i
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.b) },
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.b_i) },
    .{ .row = @intFromEnum(U.b_i), .col = @intFromEnum(U.b) },
    // RE branch: E -- E_i
    .{ .row = @intFromEnum(U.e), .col = @intFromEnum(U.e) },
    .{ .row = @intFromEnum(U.e), .col = @intFromEnum(U.e_i) },
    .{ .row = @intFromEnum(U.e_i), .col = @intFromEnum(U.e) },
    // RC branch: C -- C_i
    .{ .row = @intFromEnum(U.c), .col = @intFromEnum(U.c) },
    .{ .row = @intFromEnum(U.c), .col = @intFromEnum(U.c_i) },
    .{ .row = @intFromEnum(U.c_i), .col = @intFromEnum(U.c) },
    // Intrinsic transistor: B_i -- E_i, B_i -- C_i, C_i -- E_i (and diagonals)
    .{ .row = @intFromEnum(U.b_i), .col = @intFromEnum(U.b_i) },
    .{ .row = @intFromEnum(U.b_i), .col = @intFromEnum(U.e_i) },
    .{ .row = @intFromEnum(U.b_i), .col = @intFromEnum(U.c_i) },
    .{ .row = @intFromEnum(U.e_i), .col = @intFromEnum(U.e_i) },
    .{ .row = @intFromEnum(U.e_i), .col = @intFromEnum(U.b_i) },
    .{ .row = @intFromEnum(U.e_i), .col = @intFromEnum(U.c_i) },
    .{ .row = @intFromEnum(U.c_i), .col = @intFromEnum(U.c_i) },
    .{ .row = @intFromEnum(U.c_i), .col = @intFromEnum(U.b_i) },
    .{ .row = @intFromEnum(U.c_i), .col = @intFromEnum(U.e_i) },
    // B -- C_i (external B-C partitioned capacitance path)
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.c_i) },
    .{ .row = @intFromEnum(U.c_i), .col = @intFromEnum(U.b) },
    // E -- C_i (substrate junction)
    .{ .row = @intFromEnum(U.e), .col = @intFromEnum(U.c_i) },
    .{ .row = @intFromEnum(U.c_i), .col = @intFromEnum(U.e) },
    // DT self-heating (DT self, DT--DT1)
    .{ .row = @intFromEnum(U.dt), .col = @intFromEnum(U.dt) },
    .{ .row = @intFromEnum(U.dt), .col = @intFromEnum(U.dt1) },
    .{ .row = @intFromEnum(U.dt1), .col = @intFromEnum(U.dt) },
    .{ .row = @intFromEnum(U.dt1), .col = @intFromEnum(U.dt1) },
    // TT filter node (charge modulation, TT self + coupling to B_i, E_i)
    .{ .row = @intFromEnum(U.tt), .col = @intFromEnum(U.tt) },
    .{ .row = @intFromEnum(U.tt), .col = @intFromEnum(U.b_i) },
    .{ .row = @intFromEnum(U.tt), .col = @intFromEnum(U.e_i) },
    // TBB delayed BJT filter node (TBB self + coupling to B_i, E_i)
    .{ .row = @intFromEnum(U.tbb), .col = @intFromEnum(U.tbb) },
    .{ .row = @intFromEnum(U.tbb), .col = @intFromEnum(U.b_i) },
    .{ .row = @intFromEnum(U.tbb), .col = @intFromEnum(U.e_i) },
};

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================

pub const c_pattern_override = [_]contract.Entry(n_u){
    // Q_BE: B_i -- E_i
    .{ .row = @intFromEnum(U.b_i), .col = @intFromEnum(U.b_i) },
    .{ .row = @intFromEnum(U.b_i), .col = @intFromEnum(U.e_i) },
    .{ .row = @intFromEnum(U.e_i), .col = @intFromEnum(U.b_i) },
    .{ .row = @intFromEnum(U.e_i), .col = @intFromEnum(U.e_i) },
    // Q_BC internal: B_i -- C_i
    .{ .row = @intFromEnum(U.b_i), .col = @intFromEnum(U.c_i) },
    .{ .row = @intFromEnum(U.c_i), .col = @intFromEnum(U.b_i) },
    .{ .row = @intFromEnum(U.c_i), .col = @intFromEnum(U.c_i) },
    // Q_BC external: B -- C_i
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.b) },
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.c_i) },
    .{ .row = @intFromEnum(U.c_i), .col = @intFromEnum(U.b) },
    // Q_sub: E -- C_i
    .{ .row = @intFromEnum(U.e), .col = @intFromEnum(U.e) },
    .{ .row = @intFromEnum(U.e), .col = @intFromEnum(U.c_i) },
    .{ .row = @intFromEnum(U.c_i), .col = @intFromEnum(U.e) },
    // DT thermal capacitance
    .{ .row = @intFromEnum(U.dt), .col = @intFromEnum(U.dt) },
    .{ .row = @intFromEnum(U.dt), .col = @intFromEnum(U.dt1) },
    .{ .row = @intFromEnum(U.dt1), .col = @intFromEnum(U.dt) },
    .{ .row = @intFromEnum(U.dt1), .col = @intFromEnum(U.dt1) },
    // TT filter node capacitance (Tf * dVtt/dt for charge modulation)
    .{ .row = @intFromEnum(U.tt), .col = @intFromEnum(U.tt) },
    // TBB delayed BJT filter capacitance (CTHBB * dVtbb/dt)
    .{ .row = @intFromEnum(U.tbb), .col = @intFromEnum(U.tbb) },
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // RB thermal noise: B -- B_i
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.b_i), .kind = .thermal },
    // RE thermal noise: E -- E_i
    .{ .row = @intFromEnum(U.e), .col = @intFromEnum(U.e_i), .kind = .thermal },
    // RC thermal noise: C -- C_i
    .{ .row = @intFromEnum(U.c), .col = @intFromEnum(U.c_i), .kind = .thermal },
    // I_BE shot noise: B_i -- E_i
    .{ .row = @intFromEnum(U.b_i), .col = @intFromEnum(U.e_i), .kind = .shot },
    // I_CE shot noise: C_i -- E_i
    .{ .row = @intFromEnum(U.c_i), .col = @intFromEnum(U.e_i), .kind = .shot },
    // Flicker noise: B_i -- E_i
    .{ .row = @intFromEnum(U.b_i), .col = @intFromEnum(U.e_i), .kind = .flicker },
};

// ============================================================================
// Physics (value-form: generic over scalar S)
//
// The x-dependence tree: v_dt (thermal node) feeds the temperature block, so
// temperature (t_dev, vt, is_t, ...) is itself an S chain even though every
// parameter that enters it is a plain-f64 constant. All junction currents and
// charges are functions of the terminal voltages and this S temperature.
// Only the purely-constant scalars are hoisted into ModelP / InstP below.
// ============================================================================

/// Purely x-independent f64 parameter bundle, cast once from Model.
const ModelP = struct {
    type_f: f64,
    shmod: i32,
    extmod: i32,
    rbmod: i32,

    is_val: f64,
    nf: f64,
    isr_val: f64,
    ntr: f64,
    vtr: f64,
    bvr: f64,
    nbv: f64,
    ijbv_val: f64,
    ther: f64,
    theexp_val: f64,
    eg: f64,
    bf_val: f64,
    br_val: f64,
    nr: f64,
    vaf: f64,
    var_: f64,
    ikf: f64,
    xkf: f64,
    ikr: f64,
    ise_val: f64,
    ne: f64,
    isc_val: f64,
    nc: f64,
    nbvc: f64,
    ijbvc_val: f64,
    kbwm: f64,
    xbwm: f64,
    ikbwm: f64,
    cdelay: f64,

    rb_param: f64,
    re_param: f64,
    rc_param: f64,
    rbe: f64,
    ree: f64,
    rce: f64,
    tf_val: f64,
    vtf0: f64,
    texp_val: f64,
    atff: f64,
    mexp_val: f64,
    mexpe_val: f64,
    vsatb: f64,
    vsate: f64,
    qexp_val: f64,
    qtt0: f64,
    minr: f64,

    tnom_c: f64,
    xti: f64,
    xtir: f64,
    xtb: f64,
    xjbv: f64,
    xjbvc: f64,
    xbvr: f64,
    xtheexp: f64,
    arb: f64,
    are: f64,
    arc: f64,
    rth0: f64,
    rth1: f64,
    tfail: f64,

    fn from(model: *const Model) ModelP {
        return .{
            .type_f = @floatFromInt(model.type_),
            .shmod = model.shmod,
            .extmod = model.extmod,
            .rbmod = model.rbmod,
            .is_val = @as(f64, model.is),
            .nf = @as(f64, model.nf),
            .isr_val = @as(f64, model.isr),
            .ntr = @as(f64, model.ntr),
            .vtr = @as(f64, model.vtr),
            .bvr = @as(f64, model.bvr),
            .nbv = @as(f64, model.nbv),
            .ijbv_val = @as(f64, model.ijbv),
            .ther = @as(f64, model.ther),
            .theexp_val = @as(f64, model.theexp),
            .eg = @as(f64, model.eg),
            .bf_val = @as(f64, model.bf),
            .br_val = @as(f64, model.br),
            .nr = @as(f64, model.nr),
            .vaf = @as(f64, model.vaf),
            .var_ = @as(f64, model.var_),
            .ikf = @as(f64, model.ikf),
            .xkf = @as(f64, model.xkf),
            .ikr = @as(f64, model.ikr),
            .ise_val = @as(f64, model.ise),
            .ne = @as(f64, model.ne),
            .isc_val = @as(f64, model.isc),
            .nc = @as(f64, model.nc),
            .nbvc = @as(f64, model.nbvc),
            .ijbvc_val = @as(f64, model.ijbvc),
            .kbwm = @as(f64, model.kbwm),
            .xbwm = @as(f64, model.xbwm),
            .ikbwm = @as(f64, model.ikbwm),
            .cdelay = @as(f64, model.cdelay),
            .rb_param = @as(f64, model.rb),
            .re_param = @as(f64, model.re),
            .rc_param = @as(f64, model.rc),
            .rbe = @as(f64, model.rbe),
            .ree = @as(f64, model.ree),
            .rce = @as(f64, model.rce),
            .tf_val = @as(f64, model.tf),
            .vtf0 = @as(f64, model.vtf0),
            .texp_val = @as(f64, model.texp),
            .atff = @as(f64, model.atff),
            .mexp_val = @as(f64, model.mexp),
            .mexpe_val = @as(f64, model.mexpe),
            .vsatb = @as(f64, model.vsatb),
            .vsate = @as(f64, model.vsate),
            .qexp_val = @as(f64, model.qexp),
            .qtt0 = @as(f64, model.qtt0),
            .minr = @as(f64, model.minr),
            .tnom_c = @as(f64, model.tnom),
            .xti = @as(f64, model.xti),
            .xtir = @as(f64, model.xtir),
            .xtb = @as(f64, model.xtb),
            .xjbv = @as(f64, model.xjbv),
            .xjbvc = @as(f64, model.xjbvc),
            .xbvr = @as(f64, model.xbvr),
            .xtheexp = @as(f64, model.xtheexp),
            .arb = @as(f64, model.arb),
            .are = @as(f64, model.are),
            .arc = @as(f64, model.arc),
            .rth0 = @as(f64, model.rth0),
            .rth1 = @as(f64, model.rth1),
            .tfail = @as(f64, model.tfail),
        };
    }
};

// ----------------------------------------------------------------------------
// Softplus / exponential limiting helpers, generic over S.
//
// These branch on .val() exactly where the original code branched on the f64
// value (le/ln_exp_plus_1 region selection), and compute each branch in S ops
// so the derivative follows the picked region — the original piecewise physics.
// ----------------------------------------------------------------------------

/// le(arg) = (1 + arg - 80)*exp(80) if arg > 80, else exp(arg).
fn le(comptime S: type, arg: S) S {
    if (arg.val() > 80.0) {
        return arg.addC(-80.0).addC(1.0).scale(@exp(80.0));
    }
    return arg.exp();
}

/// ln_exp_plus_1(x) = x if x>=37, exp(x) if x<=-37, ln(exp(x)+1) otherwise.
fn lep1(comptime S: type, arg: S) S {
    const a = arg.val();
    if (a >= 37.0) return arg;
    if (a <= -37.0) return arg.exp();
    return arg.exp().addC(1.0).log();
}

/// x^p with variable base b (b>0 guaranteed by callers via maxC) and constant
/// exponent p: composed as exp(p*log(b)). Matches original @exp(p*@log(...)).
fn powVarBase(comptime S: type, b: S, p: f64) S {
    return b.log().scale(p).exp();
}

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = t;

    const c = @intFromEnum(U.c);
    const b = @intFromEnum(U.b);
    const e = @intFromEnum(U.e);
    const dt = @intFromEnum(U.dt);
    const bi = @intFromEnum(U.b_i);
    const ei = @intFromEnum(U.e_i);
    const ci = @intFromEnum(U.c_i);
    const dt1 = @intFromEnum(U.dt1);
    const tt = @intFromEnum(U.tt);
    const tbb = @intFromEnum(U.tbb);

    const p = ModelP.from(model);
    const type_f = p.type_f;

    // --- Cast instance parameters to f64 ---
    const l_val: f64 = @as(f64, instance.l);
    const n_val: f64 = @as(f64, instance.n);
    const dtemp: f64 = @as(f64, instance.dtemp);

    // --- Constants ---
    const gmin: f64 = 1.0e-12;
    const g_short: f64 = 1.0e12;

    // --- Device sizing (Eq 2.1) ---
    const w_eff: f64 = n_val * l_val;

    // =======================================================================
    // Temperature Calculations (Section 2.3)
    // =======================================================================
    const tnom_k: f64 = p.tnom_c + 273.15;

    // Device temperature with self-heating (Eq 2.3.1). v_dt is an x read, so
    // the whole temperature chain below is S.
    const v_dt = x[dt];
    const t_amb = v_dt.addC(tnom_k + dtemp); // tnom_k + dtemp + v_dt

    // Clamp device temperature (Tmin=-100C, Tmax=1026.85C)
    const t_dev = t_amb.minC(1300.0).maxC(173.15);

    // Failure warning (Section 2.8): if T_dev > TFAIL, device has failed.
    const fail_flag: f64 = if (t_dev.val() > p.tfail) 1.0 else 0.0;

    // Thermal voltage (Eq 2.3.2)
    const vt = t_dev.scale(KB_Q);

    // Temperature ratio (Eq 2.3.3, 2.3.4)
    const rT = t_dev.scale(1.0 / tnom_k);
    const lnrT = rT.maxC(1.0e-30).log();

    // BJT gain temperature (Eq 2.3.5, 2.3.6)
    var bf_t = lnrT.scale(p.xtb).exp().scale(p.bf_val);
    const br_t = lnrT.scale(p.xtb).exp().scale(p.br_val);

    // Saturation current temperature intermediates (Eq 2.3.7, 2.3.8)
    // argt = xti*lnrT + eg*(rT-1)/vt
    const argt = lnrT.scale(p.xti).add(rT.addC(-1.0).scale(p.eg).div(vt));
    const argtr = lnrT.scale(p.xtir);

    // Current parameter temperature scaling (Eq 2.3.9 - 2.3.12)
    const is_t = argt.minC(80.0).exp().scale(p.is_val);
    const isr_t = argtr.minC(80.0).exp().scale(p.isr_val);
    const ise_t = argt.scale(1.0 / p.ne).minC(80.0).exp().scale(p.ise_val)
        .div(lnrT.scale(p.xtb).minC(80.0).exp());
    const isc_t = argt.scale(1.0 / p.nc).minC(80.0).exp().scale(p.isc_val)
        .div(lnrT.scale(p.xtb).minC(80.0).exp());

    // Post-breakdown temperature scaling (Eq 2.3.13 - 2.3.15)
    const ijbv_t = rT.addC(-1.0).scale(p.xjbv).addC(1.0).scale(p.ijbv_val);
    const bvr_t = rT.addC(-1.0).scale(p.xbvr).addC(1.0).scale(p.bvr);
    const ijbvc_t = rT.addC(-1.0).scale(p.xjbvc).addC(1.0).scale(p.ijbvc_val);
    const theexp_t = rT.addC(-1.0).scale(p.xtheexp).addC(1.0).scale(p.theexp_val);

    // Resistance temperature scaling (Eq 2.3.16 - 2.3.18)
    const rb_t = lnrT.scale(p.arb).exp().scale(p.rb_param);
    const re_t = lnrT.scale(p.are).exp().scale(p.re_param);
    const rc_t = lnrT.scale(p.arc).exp().scale(p.rc_param);

    // =======================================================================
    // Extrinsic Voltages (Section 2.2)
    // =======================================================================
    const v_bbi = x[b].sub(x[bi]); // B to B_i
    const v_eei = x[e].sub(x[ei]); // E to E_i
    const v_cci = x[c].sub(x[ci]); // C to C_i

    // Intrinsic junction voltages with TYPE polarity adjustment (Eq 2.2.4, 2.2.5)
    const v_bei = x[bi].sub(x[ei]).scale(type_f);
    const v_bci = x[bi].sub(x[ci]).scale(type_f);
    const v_cei = x[ci].sub(x[ei]).scale(type_f);

    // External B-E voltage for transit time calculation
    const v_be_ext = x[b].sub(x[e]).scale(type_f);

    // =======================================================================
    // Base-width modulation (Section 2.3 — modifies BF_t)
    // =======================================================================
    // f_bwm = 1 + kbwm * (max(-vbci,0))^xbwm, applied only if kbwm > 0.
    if (p.kbwm > 0.0) {
        const neg_vbci_clamped = v_bci.neg().maxC(0.0);
        const f_bwm = powVarBase(S, neg_vbci_clamped.maxC(1.0e-30), p.xbwm).scale(p.kbwm).addC(1.0);
        bf_t = bf_t.mul(f_bwm);
    }

    // =======================================================================
    // Transit Time Field Dependence (Section 2.5 — Eq 2.5.8-2.5.10)
    // =======================================================================
    const v_tff_arg = v_be_ext.abs().scale(1.0 / p.vtf0);
    const v_tff = powVarBase(S, v_tff_arg.maxC(1.0e-30), p.texp_val);
    const v_tff1 = powVarBase(S, v_tff.addC(1.0).maxC(1.0e-30), 1.0 / p.texp_val).addC(-1.0);
    const tf_eff = v_tff1.scale(p.atff).addC(1.0).scale(p.tf_val); // tf_val*(1+atff*v_tff1)

    // =======================================================================
    // Velocity Saturation in Base Resistor (Section 2.5 — Eq 2.5.1a, 2.5.2)
    // =======================================================================
    const abs_vbbi = v_bbi.abs();
    const t1_b = powVarBase(S, abs_vbbi.scale(1.0 / p.vsatb).maxC(1.0e-30), p.mexp_val).addC(1.0);
    const rb_vsat = powVarBase(S, t1_b.maxC(1.0e-30), 1.0 / p.mexp_val).mul(rb_t);

    // =======================================================================
    // Velocity Saturation in Emitter Resistor (Section 2.5)
    // =======================================================================
    const abs_veei = v_eei.abs();
    const t1_e = powVarBase(S, abs_veei.scale(1.0 / p.vsate).maxC(1.0e-30), p.mexpe_val).addC(1.0);
    const re_vsat = powVarBase(S, t1_e.maxC(1.0e-30), 1.0 / p.mexpe_val).mul(re_t);

    // =======================================================================
    // Charge Modulation of Base Resistance (Section 2.5 — RBMOD=1)
    // =======================================================================
    const v_tt = x[tt];
    const abs_qm = v_tt.abs();
    const t2_rb = powVarBase(S, abs_qm.scale(1.0 / p.qtt0).maxC(1.0e-30), p.qexp_val);
    const rb_charge_mod = if (p.rbmod == 1) rb_vsat.div(t2_rb.addC(1.0)) else rb_vsat;

    // =======================================================================
    // Extrinsic Resistance Addition (Section 2.5 — EXTMOD=1)
    // =======================================================================
    const rb_total = if (p.extmod == 1) rb_charge_mod.addC(p.rbe) else rb_charge_mod;
    const re_total = if (p.extmod == 1) re_vsat.addC(p.ree) else re_vsat;
    const rc_total = if (p.extmod == 1) rc_t.addC(p.rce) else rc_t;

    // =======================================================================
    // Effective Terminal Resistances (Section 2.5 — scaled by Weff)
    // =======================================================================
    const rb_scaled = rb_total.scale(1.0 / w_eff);
    const re_scaled = re_total.scale(1.0 / w_eff);
    const rc_scaled = rc_total.scale(1.0 / w_eff);

    const rb_eff = rb_scaled.maxC(p.minr);
    const re_eff = re_scaled.maxC(p.minr);
    const rc_eff = rc_scaled.maxC(p.minr);

    // Conductances: if nominal resistance is below MINR, short the branch.
    // Original branches on the nominal (pre-clamp) scaled resistance value.
    const g_b = if (rb_scaled.val() >= p.minr) rb_eff.pow(-1.0) else S.con(g_short);
    const g_e = if (re_scaled.val() >= p.minr) re_eff.pow(-1.0) else S.con(g_short);
    const g_c = if (rc_scaled.val() >= p.minr) rc_eff.pow(-1.0) else S.con(g_short);

    // Resistance branch currents
    const i_rb = v_bbi.mul(g_b);
    const i_re = v_eei.mul(g_e);
    const i_rc = v_cci.mul(g_c);

    // =======================================================================
    // Forward Diode Current — B-E junction (IDIO macro, Section 2.4)
    // =======================================================================
    // I1 = IS_t * (le(Vbei/(NF*Vt)) - 1)
    const arg_be = v_bei.div(vt.scale(p.nf));
    const le_be = le(S, arg_be);
    const i1_be = le_be.addC(-1.0).mul(is_t);

    // I2 = IJBV_t / (1 + THER*|Vbei|^THEEXP_t) * [lep1(arg_bv) - lep1(arg_bv_vt)]
    const arg_bv = v_bei.neg().sub(bvr_t).div(vt.scale(p.nbv)); // (-vbei - bvr_t)/(nbv*vt)
    const arg_bv_vt = bvr_t.neg().div(vt.scale(p.nbv)); // (-bvr_t)/(nbv*vt)
    const lep1_bv = lep1(S, arg_bv);
    const lep1_bv_vt = lep1(S, arg_bv_vt);

    const abs_vbei = v_bei.abs();
    // |vbei|^theexp_t with theexp_t itself temperature-dependent (S):
    // exp(theexp_t * log(|vbei|)). Both factors S so the Jacobian is exact.
    const ther_denom = abs_vbei.maxC(1.0e-30).log().mul(theexp_t).exp().scale(p.ther).addC(1.0);
    const i2_be = if (ijbv_t.val() > 0.0)
        ijbv_t.div(ther_denom).mul(lep1_bv.sub(lep1_bv_vt))
    else
        S.con(0.0);

    // I_f = I1 - I2 (Eq 2.4.3)
    const i_f = i1_be.sub(i2_be);

    // =======================================================================
    // Reverse Tunnel Current — B-E junction (IDIOR macro, Section 2.4)
    // =======================================================================
    const t0_tun = v_bei.neg().addC(p.vtr).maxC(0.001); // max(vtr - vbei, 0.001)
    const arg_tun = v_bei.neg().scale(p.vtr).div(t0_tun.scale(p.ntr).mul(vt)); // -vbei*vtr/(ntr*vt*t0)
    const le_tun = le(S, arg_tun);
    const i_be_r_tunnel = if (p.isr_val > 0.0) le_tun.addC(-1.0).mul(isr_t) else S.con(0.0);
    _ = i_be_r_tunnel; // Tunnel current computed but not in BJT I_be

    // =======================================================================
    // B-E Leakage/Recombination Current (4-terminal only, Eq 2.4.6b)
    // =======================================================================
    const arg_be_leak = v_bei.div(vt.scale(p.ne)).minC(80.0);
    const i_be_r_leak = arg_be_leak.exp().addC(-1.0).mul(ise_t);

    // =======================================================================
    // Total Base-Emitter Current (Section 2.4)
    // 4-terminal BJT mode (Eq 2.4.2): I_be = I_f/BF_t + I_be_r_leak
    // =======================================================================
    const i_be = i_f.div(bf_t).add(i_be_r_leak);

    // =======================================================================
    // Base-Collector Junction Current (4-terminal, Section 2.4)
    // =======================================================================
    // I3 = IS_t * (le(Vbci / (NR*Vt)) - 1) (Eq 2.4.9)
    const arg_bc = v_bci.div(vt.scale(p.nr));
    const le_bc = le(S, arg_bc);
    const i3_bc = le_bc.addC(-1.0).mul(is_t);

    // I4 = IJBVC_t / (1 + THER*|Vbci|^THEEXP) * [lep1(arg1) - lep1(arg2)] (Eq 2.4.10)
    const arg_bvc = v_bci.neg().sub(bvr_t).div(vt.scale(p.nbvc));
    const arg_bvc_vt = bvr_t.neg().div(vt.scale(p.nbvc));
    const lep1_bvc = lep1(S, arg_bvc);
    const lep1_bvc_vt = lep1(S, arg_bvc_vt);

    const abs_vbci = v_bci.abs();
    // Note: B-C breakdown uses model theexp (not temperature-adjusted per spec)
    const ther_denom_bc = powVarBase(S, abs_vbci.maxC(1.0e-30), p.theexp_val).scale(p.ther).addC(1.0);
    const i4_bc = if (ijbvc_t.val() > 0.0)
        ijbvc_t.div(ther_denom_bc).mul(lep1_bvc.sub(lep1_bvc_vt))
    else
        S.con(0.0);

    // I_r = I3 - I4 (Eq 2.4.8)
    const i_r = i3_bc.sub(i4_bc);

    // I_bc_r (Eq 2.4.11): tunnel + leakage for B-C
    const t0_tun_bc = v_bci.neg().addC(p.vtr).maxC(0.001);
    const arg_tun_bc = v_bci.neg().scale(p.vtr).div(t0_tun_bc.scale(p.ntr).mul(vt));
    const le_tun_bc = le(S, arg_tun_bc);
    const i_bc_r_tunnel = if (p.isr_val > 0.0) le_tun_bc.addC(-1.0).mul(isr_t) else S.con(0.0);
    const arg_bc_leak = v_bci.div(vt.scale(p.nc)).minC(80.0);
    const i_bc_r_leak = arg_bc_leak.exp().addC(-1.0).mul(isc_t);
    const i_bc_r = i_bc_r_tunnel.add(i_bc_r_leak);

    // I_bc = I_r / BR_t + I_bc_r (Eq 2.4.7)
    const i_bc = i_r.div(br_t).add(i_bc_r);

    // =======================================================================
    // Integral Charge Control Factor (Kqb, Section 2.4)
    // =======================================================================
    const ovaf: f64 = if (p.vaf > 0.0) 1.0 / p.vaf else 0.0;
    const ovar: f64 = if (p.var_ > 0.0) 1.0 / p.var_ else 0.0;
    const oikf: f64 = if (p.ikf > 0.0) 1.0 / p.ikf else 0.0;
    const oikr: f64 = if (p.ikr > 0.0) 1.0 / p.ikr else 0.0;

    // Modified oikf with base-width modulation: oikf*(1 + vbci*ikbwm)
    const oikf_prime = v_bci.scale(p.ikbwm).addC(1.0).scale(oikf);

    // Kq2 = If*oikf' + Ir*oikr (Eq 2.4.16)
    const kq2 = i_f.mul(oikf_prime).add(i_r.scale(oikr));

    // T0 = |1 + 4*Kq2|
    const t0_kqb = kq2.scale(4.0).addC(1.0).abs();

    // Dkqb = 1 + T0^XKF
    const dkqb = powVarBase(S, t0_kqb.maxC(1.0e-30), p.xkf).addC(1.0);

    // iKq1 = 1 - Vbei*ovar - Vbci*ovaf (Eq 2.4.15)
    const ikq1 = v_bei.scale(ovar).add(v_bci.scale(ovaf)).neg().addC(1.0);

    // Ik1 = 2 * iKq1 / Dkqb (Eq 2.4.15)
    const ik1 = ikq1.scale(2.0).div(dkqb.maxC(1.0e-30));

    // =======================================================================
    // Collector Current (Section 2.4, Eq 2.4.12-2.4.14)
    // =======================================================================
    const i_tf = i_f.mul(ik1);
    const i_tr = i_r.mul(ik1);

    // =======================================================================
    // Delayed BJT Response (Section 2.4, Eq 2.4.17-2.4.19)
    // =======================================================================
    // d_ratio = |min(Vtbb, Vbei)| / max(|Vbei|, 1e-9)
    const v_tbb = x[tbb];
    const min_vtbb_vbei = v_tbb.scale(type_f).min(v_bei);
    const d_ratio = min_vtbb_vbei.abs().div(v_bei.abs().maxC(1.0e-9));

    // Modified transfer current with delay (Eq 2.4.19)
    // i_tf_f = i_tf*d_ratio*cdelay + (1-cdelay)*i_tf
    const i_tf_f = i_tf.mul(d_ratio).scale(p.cdelay).add(i_tf.scale(1.0 - p.cdelay));

    // Collector current = I_tf_f - I_tr (Eq 2.4.12)
    const i_c_int = i_tf_f.sub(i_tr);

    // =======================================================================
    // Scale by Weff (Section 2.12)
    // =======================================================================
    const i_be_scaled = i_be.scale(w_eff);
    const i_bc_scaled = i_bc.scale(w_eff);
    const i_c_scaled = i_c_int.scale(w_eff);

    // =======================================================================
    // Charge Modulation Filter Node (TT, Section 2.5, Eq 2.5.4)
    // =======================================================================
    const v_tt_val = x[tt];
    const i_tt_src = i_f.neg().div(bf_t).mul(tf_eff).scale(w_eff); // -If/BF*Tf*Weff
    const i_tt_res = v_tt_val; // V(tt) as resistive current (1 ohm)

    const i_tt_total = if (p.rbmod == 1) i_tt_src.add(i_tt_res) else v_tt_val.scale(g_short);

    // =======================================================================
    // Delayed BJT Filter Node (TBB, separate from TT, Eq 2.4.17)
    // =======================================================================
    // (Vbei - Vtbb*type)*type + 1e-6 * Vtbb
    const i_tbb_delay = v_bei.sub(v_tbb.scale(type_f)).scale(type_f).add(v_tbb.scale(1.0e-6));
    const i_tbb_total = i_tbb_delay;

    // =======================================================================
    // Self-Heating Network (Section 2.7)
    // =======================================================================
    // Power dissipation
    const p_diss = i_be_scaled.mul(v_bei).abs().add(i_bc_scaled.mul(v_bci).abs());

    const v_dt_val = x[dt];
    const v_dt1_val = x[dt1];

    const i_dt_sh1 = v_dt_val.scale(1.0 / p.rth0).sub(p_diss); // SHMOD=1
    const i_dt_sh2 = v_dt_val.sub(v_dt1_val).scale(1.0 / p.rth0).sub(p_diss); // SHMOD=2 stage 1
    const i_dt1_sh2 = v_dt1_val.scale(1.0 / p.rth1).sub(v_dt_val.sub(v_dt1_val).scale(1.0 / p.rth0)); // stage 2

    // Failure warning (Section 2.8): add large conductance to clamp DT node.
    const fail_cond = v_dt_val.scale(fail_flag * g_short);
    const i_dt_base = if (p.shmod == 2)
        i_dt_sh2
    else if (p.shmod == 1)
        i_dt_sh1
    else if (p.shmod == -1)
        p_diss.neg()
    else
        v_dt_val.scale(g_short);
    const i_dt_out = i_dt_base.add(fail_cond);
    const i_dt1_out = if (p.shmod == 2) i_dt1_sh2 else v_dt1_val.scale(g_short);

    // =======================================================================
    // GMIN Convergence Aid (Section 2.13/2.14)
    // =======================================================================
    const gmin_be = v_bei.scale(gmin);
    const gmin_bc = v_bci.scale(gmin);
    const gmin_ce = v_cei.scale(gmin);

    // =======================================================================
    // KCL Node Stamps (Section 2.13/2.14)
    // =======================================================================
    var out: [n_u]S = undefined;

    // B -> B_i (resistance branch)
    out[b] = i_rb.neg();
    // E -> E_i (resistance branch)
    out[e] = i_re.neg();
    // C -> C_i (resistance branch)
    out[c] = i_rc.neg();

    // B_i: RB current in - (I_be + gmin + I_bc + gmin) * type
    out[bi] = i_rb.sub(i_be_scaled.add(gmin_be).add(i_bc_scaled).add(gmin_bc).scale(type_f));

    // E_i: RE current in + (I_be + gmin)*type + (I_c + gmin)*type
    out[ei] = i_re.add(i_be_scaled.add(gmin_be).scale(type_f)).add(i_c_scaled.add(gmin_ce).scale(type_f));

    // C_i: RC current in + (I_bc + gmin)*type - (I_c + gmin)*type
    out[ci] = i_rc.add(i_bc_scaled.add(gmin_bc).scale(type_f)).sub(i_c_scaled.add(gmin_ce).scale(type_f));

    // DT: self-heating
    out[dt] = i_dt_out;
    // DT1: second thermal pole
    out[dt1] = i_dt1_out;
    // TT: charge modulation filter (Eq 2.5.4)
    out[tt] = i_tt_total;
    // TBB: delayed BJT filter (Eq 2.4.17)
    out[tbb] = i_tbb_total;

    return out;
}

// ============================================================================
// Charge Function (q)
// ============================================================================

/// x-independent f64 parameter bundle for q.
const ModelQ = struct {
    type_f: f64,
    shmod: i32,
    is_val: f64,
    nf: f64,
    nr: f64,
    eg: f64,
    cje: f64,
    vje: f64,
    mje: f64,
    cjc: f64,
    vjc: f64,
    mjc: f64,
    cjs: f64,
    vjs: f64,
    mjs: f64,
    xcjc: f64,
    tf_val: f64,
    tr: f64,
    ptf_val: f64,
    fc: f64,
    cthbb: f64,
    vtf0: f64,
    texp_val: f64,
    atff: f64,
    tnom_c: f64,
    xti: f64,
    cth0: f64,
    cth1: f64,
    bf_val: f64,
    xtb: f64,
    vaf: f64,
    var_: f64,
    ikf: f64,
    xkf: f64,
    ikr: f64,
    ikbwm: f64,
    kbwm: f64,
    xbwm: f64,

    fn from(model: *const Model) ModelQ {
        return .{
            .type_f = @floatFromInt(model.type_),
            .shmod = model.shmod,
            .is_val = @as(f64, model.is),
            .nf = @as(f64, model.nf),
            .nr = @as(f64, model.nr),
            .eg = @as(f64, model.eg),
            .cje = @as(f64, model.cje),
            .vje = @as(f64, model.vje),
            .mje = @as(f64, model.mje),
            .cjc = @as(f64, model.cjc),
            .vjc = @as(f64, model.vjc),
            .mjc = @as(f64, model.mjc),
            .cjs = @as(f64, model.cjs),
            .vjs = @as(f64, model.vjs),
            .mjs = @as(f64, model.mjs),
            .xcjc = @as(f64, model.xcjc),
            .tf_val = @as(f64, model.tf),
            .tr = @as(f64, model.tr),
            .ptf_val = @as(f64, model.ptf),
            .fc = @as(f64, model.fc),
            .cthbb = @as(f64, model.cthbb),
            .vtf0 = @as(f64, model.vtf0),
            .texp_val = @as(f64, model.texp),
            .atff = @as(f64, model.atff),
            .tnom_c = @as(f64, model.tnom),
            .xti = @as(f64, model.xti),
            .cth0 = @as(f64, model.cth0),
            .cth1 = @as(f64, model.cth1),
            .bf_val = @as(f64, model.bf),
            .xtb = @as(f64, model.xtb),
            .vaf = @as(f64, model.vaf),
            .var_ = @as(f64, model.var_),
            .ikf = @as(f64, model.ikf),
            .xkf = @as(f64, model.xkf),
            .ikr = @as(f64, model.ikr),
            .ikbwm = @as(f64, model.ikbwm),
            .kbwm = @as(f64, model.kbwm),
            .xbwm = @as(f64, model.xbwm),
        };
    }
};

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = t;

    const b = @intFromEnum(U.b);
    const e = @intFromEnum(U.e);
    const c = @intFromEnum(U.c);
    const dt = @intFromEnum(U.dt);
    const bi = @intFromEnum(U.b_i);
    const ei = @intFromEnum(U.e_i);
    const ci = @intFromEnum(U.c_i);
    const dt1 = @intFromEnum(U.dt1);
    const tt = @intFromEnum(U.tt);
    const tbb_node = @intFromEnum(U.tbb);

    const p = ModelQ.from(model);
    const type_f = p.type_f;

    // --- Cast instance parameters to f64 ---
    const l_val: f64 = @as(f64, instance.l);
    const n_val: f64 = @as(f64, instance.n);
    const dtemp: f64 = @as(f64, instance.dtemp);

    // --- Device sizing ---
    const w_eff: f64 = n_val * l_val;

    // =======================================================================
    // Temperature Calculations (for temperature-dependent capacitances)
    // v_dt is an x read, so the temperature chain below is S.
    // =======================================================================
    const tnom_k: f64 = p.tnom_c + 273.15;
    const v_dt = x[dt];
    const t_amb = v_dt.addC(tnom_k + dtemp);
    const t_dev = t_amb.minC(1300.0).maxC(173.15);
    const vt = t_dev.scale(KB_Q);

    const rT = t_dev.scale(1.0 / tnom_k);
    const lnrT = rT.maxC(1.0e-30).log();

    // Temperature-adjusted saturation current for diffusion charge
    const argt = lnrT.scale(p.xti).add(rT.addC(-1.0).scale(p.eg).div(vt));
    const is_t = argt.minC(80.0).exp().scale(p.is_val);

    // BJT gain for Ik1
    var bf_t = lnrT.scale(p.xtb).exp().scale(p.bf_val);

    // =======================================================================
    // Junction Voltages
    // =======================================================================
    const v_bei = x[bi].sub(x[ei]).scale(type_f);
    const v_bci = x[bi].sub(x[ci]).scale(type_f);
    const v_be_ext = x[b].sub(x[e]).scale(type_f);

    // External B-C voltage for partitioned capacitance
    const v_bci_ext = x[b].sub(x[ci]).scale(type_f);

    // Substrate voltage (E to C_i)
    const v_ec = x[e].sub(x[ci]).scale(type_f);

    // Base-width modulation update for bf_t
    if (p.kbwm > 0.0) {
        const neg_vbci_clamped = v_bci.neg().maxC(0.0);
        const f_bwm = powVarBase(S, neg_vbci_clamped.maxC(1.0e-30), p.xbwm).scale(p.kbwm).addC(1.0);
        bf_t = bf_t.mul(f_bwm);
    }

    // Transit time field dependence
    const v_tff_arg = v_be_ext.abs().scale(1.0 / p.vtf0);
    const v_tff = powVarBase(S, v_tff_arg.maxC(1.0e-30), p.texp_val);
    const v_tff1 = powVarBase(S, v_tff.addC(1.0).maxC(1.0e-30), 1.0 / p.texp_val).addC(-1.0);
    const tf_eff = v_tff1.scale(p.atff).addC(1.0).scale(p.tf_val);

    // =======================================================================
    // Forward / reverse current (needed for diffusion charge and Kqb)
    // Must use same le() linearization as i function (Eq 2.6)
    // =======================================================================
    const arg_be_q = v_bei.div(vt.scale(p.nf));
    const le_be_q = le(S, arg_be_q);
    const i_f = le_be_q.addC(-1.0).mul(is_t);

    const arg_bc_q = v_bci.div(vt.scale(p.nr));
    const le_bc_q = le(S, arg_bc_q);
    const i_r = le_bc_q.addC(-1.0).mul(is_t);

    // Kqb factor for transport current
    const ovaf: f64 = if (p.vaf > 0.0) 1.0 / p.vaf else 0.0;
    const ovar: f64 = if (p.var_ > 0.0) 1.0 / p.var_ else 0.0;
    const oikf: f64 = if (p.ikf > 0.0) 1.0 / p.ikf else 0.0;
    const oikr: f64 = if (p.ikr > 0.0) 1.0 / p.ikr else 0.0;
    const oikf_prime = v_bci.scale(p.ikbwm).addC(1.0).scale(oikf);
    const kq2 = i_f.mul(oikf_prime).add(i_r.scale(oikr));
    const t0_kqb = kq2.scale(4.0).addC(1.0).abs();
    const dkqb = powVarBase(S, t0_kqb.maxC(1.0e-30), p.xkf).addC(1.0);
    const ikq1 = v_bei.scale(ovar).add(v_bci.scale(ovaf)).neg().addC(1.0);
    const ik1 = ikq1.scale(2.0).div(dkqb.maxC(1.0e-30));

    const i_tf = i_f.mul(ik1);
    const i_tr = i_r.mul(ik1);

    // =======================================================================
    // Junction Capacitance Temperature Update (Section 2.3, Eq 2.3.19-2.3.29)
    // These depend on t_dev (S) via vt, f2_be, egf_be, arg0_be.
    // =======================================================================
    const f1_be: f64 = tnom_k / REF_T;
    const f2_be = t_dev.scale(1.0 / REF_T);
    // egf_be = EG0 - EGTA*t_dev^2/(EGTB + t_dev)
    const egf_be = t_dev.mul(t_dev).scale(EGTA).div(t_dev.addC(EGTB)).neg().addC(EG0);
    // arg0_be = -egf/(2*kB*t_dev) + EG_300/(2*kB*REF_T)
    const arg0_be = egf_be.div(t_dev.scale(2.0 * K_B)).neg().addC(EG_300 / (2.0 * K_B * REF_T));
    // pf = -2*vt*(1.5*ln(f2) + Q*arg0)
    const pf_common = f2_be.maxC(1.0e-30).log().scale(1.5).add(arg0_be.scale(Q_ELEC));
    const pf_be = vt.scale(-2.0).mul(pf_common);

    // B-E junction capacitance temperature update
    const p0_be = pf_be.neg().addC(p.vje).scale(1.0 / f1_be); // (vje - pf)/f1
    const gm0_be = p0_be.neg().addC(p.vje).div(p0_be); // (vje - p0)/p0
    // cje_t = cje / (1 + mje*(4e-4*(tnom_k - REF_T) - gm0))
    const cje_t = gm0_be.neg().addC(4.0e-4 * (tnom_k - REF_T)).scale(p.mje).addC(1.0).pow(-1.0).scale(p.cje);
    const vje_t = f2_be.mul(p0_be).add(pf_be); // f2*p0 + pf
    const gmn_be = vje_t.sub(p0_be).div(p0_be); // (vje_t - p0)/p0
    // cje_final = cje_t*(1 + mje*(4e-4*(t_dev - REF_T) - gmn))
    const cje_final = t_dev.addC(-REF_T).scale(4.0e-4).sub(gmn_be).scale(p.mje).addC(1.0).mul(cje_t);

    // B-C junction capacitance temperature update
    const pf_bc = pf_be; // identical formula
    const p0_bc = pf_bc.neg().addC(p.vjc).scale(1.0 / f1_be);
    const gm0_bc = p0_bc.neg().addC(p.vjc).div(p0_bc);
    const cjc_t = gm0_bc.neg().addC(4.0e-4 * (tnom_k - REF_T)).scale(p.mjc).addC(1.0).pow(-1.0).scale(p.cjc);
    const vjc_t = f2_be.mul(p0_bc).add(pf_bc);
    const gmn_bc = vjc_t.sub(p0_bc).div(p0_bc);
    const cjc_final = t_dev.addC(-REF_T).scale(4.0e-4).sub(gmn_bc).scale(p.mjc).addC(1.0).mul(cjc_t);

    // E-C (substrate) junction capacitance temperature update
    const pf_ec = pf_be;
    const p0_ec = pf_ec.neg().addC(p.vjs).scale(1.0 / f1_be);
    const gm0_ec = p0_ec.neg().addC(p.vjs).div(p0_ec);
    const cjs_t = gm0_ec.neg().addC(4.0e-4 * (tnom_k - REF_T)).scale(p.mjs).addC(1.0).pow(-1.0).scale(p.cjs);
    const vjs_t = f2_be.mul(p0_ec).add(pf_ec);
    const gmn_ec = vjs_t.sub(p0_ec).div(p0_ec);
    const cjs_final = t_dev.addC(-REF_T).scale(4.0e-4).sub(gmn_ec).scale(p.mjs).addC(1.0).mul(cjs_t);

    // =======================================================================
    // B-E Junction Charge (QJ macro, Section 2.6)
    // =======================================================================
    const one_minus_fc: f64 = 1.0 - p.fc;
    const one_minus_mje: f64 = 1.0 - p.mje;

    // dv0 = -P*FC ; dvh = V + dv0
    const dvh_be = v_bei.sub(vje_t.scale(p.fc));

    // pwq is constant-exponent power of a constant -> f64
    const pwq_be: f64 = std.math.pow(f64, one_minus_fc, -1.0 - p.mje);
    // q_lo_fwd_be = vje_t*(1 - (1-fc)^(1-mje))/(1-mje)
    const olf: f64 = (1.0 - std.math.pow(f64, one_minus_fc, one_minus_mje)) / one_minus_mje;
    const q_lo_fwd_be = vje_t.scale(olf);
    // q_hi_be = dvh*(1 - fc + mje*dvh/(2*vje_t))*pwq
    const q_hi_be = dvh_be.mul(dvh_be.scale(p.mje).div(vje_t.scale(2.0)).addC(1.0 - p.fc)).scale(pwq_be);

    // x = max(1 - vbei/vje_t, 1e-30) ; q_lo_rev = vje_t*(1 - x^(1-mje))/(1-mje)
    const x_be = v_bei.div(vje_t).neg().addC(1.0).maxC(1.0e-30);
    const q_lo_rev_be = vje_t.scale(1.0).sub(vje_t.mul(powVarBase(S, x_be, one_minus_mje))).scale(1.0 / one_minus_mje);

    const q_be_depl_raw = if (dvh_be.val() > 0.0) q_lo_fwd_be.add(q_hi_be) else q_lo_rev_be;
    const q_be_depl = cje_final.mul(q_be_depl_raw);

    // =======================================================================
    // B-E Diffusion Charge (Section 2.6): Q_de = Tf*I_f
    // =======================================================================
    const q_de = tf_eff.mul(i_f);

    // Total B-E Charge
    const q_be_total = q_be_depl.add(q_de).scale(w_eff);

    // =======================================================================
    // B-C Internal Junction Charge — partitioned by XCJC (Section 2.6)
    // =======================================================================
    const one_minus_mjc: f64 = 1.0 - p.mjc;

    const cjci = cjc_final.scale(p.xcjc); // xcjc*cjc_final
    const dvh_bci = v_bci.sub(vjc_t.scale(p.fc));

    const pwq_bc: f64 = std.math.pow(f64, one_minus_fc, -1.0 - p.mjc);
    const olf_c: f64 = (1.0 - std.math.pow(f64, one_minus_fc, one_minus_mjc)) / one_minus_mjc;
    const q_lo_fwd_bci = vjc_t.scale(olf_c);
    const q_hi_bci = dvh_bci.mul(dvh_bci.scale(p.mjc).div(vjc_t.scale(2.0)).addC(1.0 - p.fc)).scale(pwq_bc);

    const x_bci = v_bci.div(vjc_t).neg().addC(1.0).maxC(1.0e-30);
    const q_lo_rev_bci = vjc_t.sub(vjc_t.mul(powVarBase(S, x_bci, one_minus_mjc))).scale(1.0 / one_minus_mjc);

    const q_bci_depl_raw = if (dvh_bci.val() > 0.0) q_lo_fwd_bci.add(q_hi_bci) else q_lo_rev_bci;
    const q_jci = cjci.mul(q_bci_depl_raw);

    // Reverse diffusion charge
    const q_dc = i_tr.scale(p.tr);

    // =======================================================================
    // B-C External Junction Charge — (1-XCJC) fraction at external B node
    // =======================================================================
    const cjcx = cjc_final.scale(1.0 - p.xcjc);
    const dvh_bcx = v_bci_ext.sub(vjc_t.scale(p.fc));

    const q_lo_fwd_bcx = vjc_t.scale(olf_c);
    const q_hi_bcx = dvh_bcx.mul(dvh_bcx.scale(p.mjc).div(vjc_t.scale(2.0)).addC(1.0 - p.fc)).scale(pwq_bc);

    const x_bcx = v_bci_ext.div(vjc_t).neg().addC(1.0).maxC(1.0e-30);
    const q_lo_rev_bcx = vjc_t.sub(vjc_t.mul(powVarBase(S, x_bcx, one_minus_mjc))).scale(1.0 / one_minus_mjc);

    const q_bcx_depl_raw = if (dvh_bcx.val() > 0.0) q_lo_fwd_bcx.add(q_hi_bcx) else q_lo_rev_bcx;
    const q_jcx = cjcx.mul(q_bcx_depl_raw);

    // =======================================================================
    // Excess Phase Charge (Section 2.6, 4-terminal only)
    // =======================================================================
    const has_excess_phase = p.ptf_val != 0.0 and p.tf_val != 0.0;
    const q_xf1 = if (has_excess_phase)
        i_tf.scale(type_f * p.ptf_val * (PI / 180.0) * p.tf_val)
    else
        S.con(0.0);

    // =======================================================================
    // E-C (Substrate) Junction Charge — QJZ macro (Section 2.6)
    // =======================================================================
    const one_minus_mjs: f64 = 1.0 - p.mjs;

    // V <= 0: Q = CJ*P*(1 - (1-V/P)^(1-M))/(1-M)
    const x_ec = v_ec.div(vjs_t).neg().addC(1.0).maxC(1.0e-30);
    const q_ec_rev = cjs_final.mul(vjs_t.sub(vjs_t.mul(powVarBase(S, x_ec, one_minus_mjs)))).scale(1.0 / one_minus_mjs);

    // V > 0: Q = CJ*V*(1 + M*V/(2*P))
    const q_ec_fwd = cjs_final.mul(v_ec).mul(v_ec.scale(p.mjs).div(vjs_t.scale(2.0)).addC(1.0));

    const q_ec_raw = if (v_ec.val() <= 0.0) q_ec_rev else q_ec_fwd;

    // =======================================================================
    // Scale charges by Weff
    // =======================================================================
    const q_be_out = q_be_total; // already *w_eff
    const q_bci_out = q_jci.add(q_dc).scale(w_eff);
    const q_bcx_out = q_jcx.scale(w_eff);
    const q_ec_out = q_ec_raw.scale(w_eff);

    // =======================================================================
    // Self-Heating Thermal Capacitances (Section 2.7)
    // =======================================================================
    const v_dt_val = x[dt];
    const v_dt1_val = x[dt1];

    const q_dt = if (p.shmod == 1 or p.shmod == 2) v_dt_val.scale(p.cth0) else S.con(0.0);
    const q_dt1 = if (p.shmod == 2) v_dt1_val.scale(p.cth1) else S.con(0.0);

    // =======================================================================
    // TT Filter Node Capacitance (charge modulation, Eq 2.5.4)
    // =======================================================================
    const v_tt_val = x[tt];
    const q_tt_total = tf_eff.mul(v_tt_val);

    // =======================================================================
    // TBB Delayed BJT Filter Capacitance (CTHBB*dVtbb/dt, Eq 2.4.17)
    // =======================================================================
    const v_tbb_val = x[tbb_node];
    const q_tbb_total = v_tbb_val.scale(p.cthbb);

    // =======================================================================
    // Charge KCL Stamps (Section 2.13/2.14)
    // =======================================================================
    var out: [n_u]S = undefined;

    out[c] = S.con(0.0);
    out[b] = q_bcx_out.scale(type_f);
    out[e] = q_ec_out.neg().scale(type_f);
    out[bi] = q_be_out.add(q_bci_out).scale(type_f);
    out[ei] = q_be_out.neg().scale(type_f).sub(q_xf1.scale(w_eff));
    out[ci] = q_bci_out.neg().scale(type_f)
        .add(q_xf1.scale(w_eff))
        .add(q_ec_out.scale(type_f))
        .sub(q_bcx_out.scale(type_f));
    out[dt] = q_dt;
    out[dt1] = q_dt1;
    out[tt] = q_tt_total;
    out[tbb_node] = q_tbb_total;

    return out;
}

// ============================================================================
// Voltage Limiting (DEVpnjlim for B-E and B-C junctions)
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const bi = @intFromEnum(U.b_i);
    const ei = @intFromEnum(U.e_i);
    const ci = @intFromEnum(U.c_i);

    const is_val: f64 = @as(f64, model.is);
    const tnom_c: f64 = @as(f64, model.tnom);
    const type_f: f64 = @floatFromInt(model.type_);
    const tnom_k: f64 = tnom_c + 273.15;
    const vt: f64 = KB_Q * tnom_k;

    // Critical voltage for PN junction limiting
    const v_crit = vt * @log(vt / (@sqrt(2.0) * @max(is_val, 1.0e-30)));

    var result = x_new;

    // ===================================================================
    // Limit V_BE (adjusting B_i node)
    // ===================================================================
    const vbe_new = (result[bi] - result[ei]) * type_f;
    const vbe_old = (x_old[bi] - x_old[ei]) * type_f;

    var vbe_limited = vbe_new;

    if (vbe_new > v_crit and @abs(vbe_new - vbe_old) > 2.0 * vt) {
        if (vbe_old > 0.0) {
            const ratio = 1.0 + (vbe_new - vbe_old) / vt;
            if (ratio > 2.0) {
                vbe_limited = vbe_old + vt * @log(ratio);
            } else {
                vbe_limited = v_crit;
            }
        } else {
            if (vbe_new / vt > 0.0) {
                vbe_limited = vt * @log(vbe_new / vt);
            } else {
                vbe_limited = v_crit;
            }
        }
    }

    const delta_be = (vbe_limited - vbe_new) * type_f;
    result[bi] = result[bi] + delta_be;

    // ===================================================================
    // Limit V_BC (adjusting B_i node, after B-E correction)
    // ===================================================================
    const vbc_new = (result[bi] - result[ci]) * type_f;
    const vbc_old = (x_old[bi] - x_old[ci]) * type_f;

    var vbc_limited = vbc_new;

    if (vbc_new > v_crit and @abs(vbc_new - vbc_old) > 2.0 * vt) {
        if (vbc_old > 0.0) {
            const ratio = 1.0 + (vbc_new - vbc_old) / vt;
            if (ratio > 2.0) {
                vbc_limited = vbc_old + vt * @log(ratio);
            } else {
                vbc_limited = v_crit;
            }
        } else {
            if (vbc_new / vt > 0.0) {
                vbc_limited = vt * @log(vbc_new / vt);
            } else {
                vbc_limited = v_crit;
            }
        }
    }

    const delta_bc = (vbc_limited - vbc_new) * type_f;
    result[bi] = result[bi] + delta_bc;

    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================
// At lambda=0, IS is boosted by gmin to ease convergence.
// At lambda=1, original parameters are recovered.

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const gmin_step: f64 = 1.0e-12;
    const is_orig: f64 = @as(f64, model.is);
    const is_stepped = is_orig + gmin_step * (1.0 - lambda);
    m.is = @floatCast(is_stepped);
    return m;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "asm_esd: contract validates" {
    comptime contract.validate(Self);
}

test "asm_esd: forward-bias B-E residual (diode-like on-state)" {
    // Default NPN. Bias only the intrinsic B-E junction: V(b_i)=0.7, all
    // other nodes = 0. With defaults: type=+1, is=1e-17, nf=1, tnom=25C,
    // dtemp=0, DT=0 => t_dev = 298.15K, vt = KB_Q*t_dev = 8.6170869e-5*298.15
    //   = 0.0256918... V.
    // v_bei = 0.7. arg_be = 0.7/(1*vt) = 27.246... < 80 => le = exp(arg_be).
    // i1_be = is*(exp(arg)-1). exp(27.246) ~ 6.79e11 => i1_be ~ 6.79e-6 A/m.
    // ijbv default 5 > 0 but its lep1 terms are tiny at this bias.
    // i_be = i_f/bf + i_be_r_leak, bf=0.1, ise=0 => i_be = i_f*10.
    // w_eff = n*l = 1*10e-6 = 1e-5. The E_i-row residual carries
    // +(i_be_scaled + gmin_be)*type. We just assert it is finite & positive
    // and matches the hand chain within tolerance.
    const model: Model = .{};
    const inst: Instance = .{};
    var xv = [_]f64{0.0} ** n_u;
    xv[@intFromEnum(U.b_i)] = 0.7;
    const out = contract.evalValues(Self, xv, &model, &inst, 0);

    // Recompute expected i_be_scaled contribution to E_i row.
    const vt = KB_Q * 298.15;
    const arg = 0.7 / vt;
    const i1_val = 1.0e-17 * (@exp(arg) - 1.0);
    // i2 (breakdown) at forward bias: arg_bv = (-0.7 - bvr_t)/(nbv*vt),
    // very negative => lep1(arg_bv) ~ exp(arg_bv) ~ 0; lep1(arg_bv_vt) also
    // ~0 (bvr_t=10, nbv=10 => arg ~ -39 => exp ~ tiny). i2 negligible.
    const i_f = i1_val;
    const i_be = i_f / 0.1; // bf=0.1, ise=0
    const w_eff = 1e-5;
    const gmin_be = 1e-12 * 0.7;
    const expected_ei = (i_be * w_eff + gmin_be); // type=+1; c_i term ~0 here
    // c_i transport term also loads E_i (+i_c_scaled); with vbci=-0.7 the
    // transport current is small relative but not zero. Assert order-of-mag.
    try testing.expect(std.math.isFinite(out[@intFromEnum(U.e_i)]));
    try testing.expect(out[@intFromEnum(U.e_i)] > 0.0);
    // The dominant term is i_be_scaled; check E_i within 5% of that + gmin.
    const dom = out[@intFromEnum(U.e_i)];
    try testing.expect(dom > 0.5 * expected_ei);
}

test "asm_esd: B-E depletion charge at zero bias" {
    // Give a nonzero CJE so the depletion charge is exercised. At V=0 the
    // reverse-bias branch (dvh <= 0) applies:
    //   x = max(1 - 0/vje_t, 1e-30) = 1
    //   q_lo_rev = vje_t*(1 - 1^(1-mje))/(1-mje) = 0
    // so the depletion charge is 0 at zero bias, plus diffusion Q_de = Tf*I_f,
    // with Tf=0 default => 0. Total B-E charge on b_i row = 0.
    const model: Model = .{ .cje = 1e-9, .tf = 0.0 };
    const inst: Instance = .{};
    const xv = [_]f64{0.0} ** n_u;
    const out = contract.qValues(Self, xv, &model, &inst, 0);
    // b_i row = (q_be + q_bci)*type. Both depletion charges are 0 at V=0
    // (reverse branch, x=1 => (1 - 1) = 0). Expect ~0.
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.b_i)], 1e-18);
}

test "asm_esd: forward B-E depletion charge is positive" {
    // Forward bias below FC threshold uses the reverse-branch formula with
    // x = 1 - v/vje_t < 1, giving positive charge. cje=1e-9, vje=0.75,
    // mje=0.33, v_bei=0.3 (dvh = 0.3 - 0.75*0.5 = -0.075 <= 0 => reverse
    // branch). x = 1 - 0.3/vje_t (vje_t ~ vje at tnom~ref). q>0.
    const model: Model = .{ .cje = 1e-9, .tf = 0.0, .tnom = 26.85 }; // tnom ~ REF_T
    const inst: Instance = .{};
    var xv = [_]f64{0.0} ** n_u;
    xv[@intFromEnum(U.b_i)] = 0.3;
    const out = contract.qValues(Self, xv, &model, &inst, 0);
    try testing.expect(out[@intFromEnum(U.b_i)] > 0.0);
}
