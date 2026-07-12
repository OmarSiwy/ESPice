const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: Gummel-Poon BJT (Berkeley SPICE3f5)
//
//   C (collector)  -- RC -- C' (intrinsic collector)
//   B (base)       -- RB -- B' (intrinsic base)
//   E (emitter)    -- RE -- E' (intrinsic emitter)
//   S (substrate)  -- substrate diode -- C'
//
//   Intrinsic transistor between B', C', E' with transport current
//   controlled by base charge (Gummel-Poon model).
//
//   NPN/PNP polarity handled by sign factor type (+1 NPN, -1 PNP).
// ============================================================================

pub const U = enum(u8) {
    c, // 0: external collector
    b, // 1: external base
    e, // 2: external emitter
    s, // 3: external substrate
    c_prime, // 4: intrinsic collector
    b_prime, // 5: intrinsic base
    e_prime, // 6: intrinsic emitter
};
pub const num_ports: usize = 4;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Device Type and Structure ---
    type_: i32 = 1, // +1 = NPN, -1 = PNP
    subs: i32 = 1, // 1 = vertical, 0 = lateral
    tnom: f32 = 27.0, // degC

    // --- DC Current Parameters ---
    is: f32 = 1.0e-16,
    ibe: f32 = 0.0,
    ibc: f32 = 0.0,
    bf: f32 = 100.0,
    nf: f32 = 1.0,
    br: f32 = 1.0,
    nr: f32 = 1.0,
    ise: f32 = 0.0,
    ne: f32 = 1.5,
    isc: f32 = 0.0,
    nc: f32 = 2.0,

    // --- Early Effect and High-Injection ---
    vaf: f32 = 0.0,
    var_: f32 = 0.0,
    ikf: f32 = 0.0,
    ikr: f32 = 0.0,
    nkf: f32 = 0.5,

    // --- Parasitic Resistances ---
    rb: f32 = 0.0,
    rbm: f32 = 0.0,
    irb: f32 = 0.0,
    re: f32 = 0.0,
    rc: f32 = 0.0,

    // --- Junction Capacitances -- Base-Emitter ---
    cje: f32 = 0.0,
    vje: f32 = 0.75,
    mje: f32 = 0.33,

    // --- Junction Capacitances -- Base-Collector ---
    cjc: f32 = 0.0,
    vjc: f32 = 0.75,
    mjc: f32 = 0.33,
    xcjc: f32 = 1.0,

    // --- Junction Capacitances -- Substrate ---
    cjs: f32 = 0.0,
    vjs: f32 = 0.75,
    mjs: f32 = 0.0,

    // --- Transit Times ---
    tf: f32 = 0.0,
    xtf: f32 = 0.0,
    vtf: f32 = 0.0,
    itf: f32 = 0.0,
    ptf: f32 = 0.0,
    tr: f32 = 0.0,
    fc: f32 = 0.5,

    // --- Substrate Diode ---
    iss: f32 = 0.0,
    ns: f32 = 1.0,

    // --- Epitaxial Region (Quasi-Saturation) ---
    rco: f32 = 0.01,
    vo: f32 = 10.0,
    gamma: f32 = 1.0e-11,
    qco: f32 = 0.0,
    quasimod: i32 = 0,

    // --- Temperature Dependence (Standard SPICE) ---
    xtb: f32 = 0.0,
    eg: f32 = 1.11,
    xti: f32 = 3.0,
    vg: f32 = 1.206,
    cn: f32 = 2.42,
    d: f32 = 0.87,

    // --- Temperature Equation Selectors ---
    tlev: i32 = 0,
    tlevc: i32 = 0,

    // --- Temperature Coefficients -- Current Gains ---
    tbf1: f32 = 0.0,
    tbf2: f32 = 0.0,
    tbr1: f32 = 0.0,
    tbr2: f32 = 0.0,

    // --- Temperature Coefficients -- Roll-Off Currents ---
    tikf1: f32 = 0.0,
    tikf2: f32 = 0.0,
    tikr1: f32 = 0.0,
    tikr2: f32 = 0.0,

    // --- Temperature Coefficients -- Base Resistance ---
    tirb1: f32 = 0.0,
    tirb2: f32 = 0.0,
    trb1: f32 = 0.0,
    trb2: f32 = 0.0,
    trm1: f32 = 0.0,
    trm2: f32 = 0.0,

    // --- Temperature Coefficients -- Emission Coefficients ---
    tnc1: f32 = 0.0,
    tnc2: f32 = 0.0,
    tne1: f32 = 0.0,
    tne2: f32 = 0.0,
    tnf1: f32 = 0.0,
    tnf2: f32 = 0.0,
    tnr1: f32 = 0.0,
    tnr2: f32 = 0.0,

    // --- Temperature Coefficients -- Parasitic Resistances ---
    trc1: f32 = 0.0,
    trc2: f32 = 0.0,
    tre1: f32 = 0.0,
    tre2: f32 = 0.0,

    // --- Temperature Coefficients -- Early Voltages ---
    tvaf1: f32 = 0.0,
    tvaf2: f32 = 0.0,
    tvar1: f32 = 0.0,
    tvar2: f32 = 0.0,

    // --- Temperature Coefficients -- Junction Capacitances ---
    ctc: f32 = 0.0,
    cte: f32 = 0.0,
    cts: f32 = 0.0,
    tvjc: f32 = 0.0,
    tvje: f32 = 0.0,
    tvjs: f32 = 0.0,
    tmje1: f32 = 0.0,
    tmje2: f32 = 0.0,
    tmjc1: f32 = 0.0,
    tmjc2: f32 = 0.0,
    tmjs1: f32 = 0.0,
    tmjs2: f32 = 0.0,

    // --- Temperature Coefficients -- Saturation Currents ---
    tis1: f32 = 0.0,
    tis2: f32 = 0.0,
    tise1: f32 = 0.0,
    tise2: f32 = 0.0,
    tisc1: f32 = 0.0,
    tisc2: f32 = 0.0,
    tiss1: f32 = 0.0,
    tiss2: f32 = 0.0,
    tns1: f32 = 0.0,
    tns2: f32 = 0.0,

    // --- Temperature Coefficients -- Transit Times ---
    titf1: f32 = 0.0,
    titf2: f32 = 0.0,
    ttf1: f32 = 0.0,
    ttf2: f32 = 0.0,
    ttr1: f32 = 0.0,
    ttr2: f32 = 0.0,

    // --- Noise ---
    kf: f32 = 0.0,
    af: f32 = 0.0,

    // --- Absolute Maximum Ratings ---
    vbe_max: f32 = std.math.inf(f32),
    vbc_max: f32 = std.math.inf(f32),
    vce_max: f32 = std.math.inf(f32),
    pd_max: f32 = std.math.inf(f32),
    ic_max: f32 = std.math.inf(f32),
    ib_max: f32 = std.math.inf(f32),
    te_max: f32 = std.math.inf(f32),
    rth0: f32 = 0.0,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    area: f32 = 1.0,
    m: f32 = 1.0,
    temp: f32 = 0.0,
    dtemp: f32 = 0.0,
};

// ============================================================================
// Sparse Conductance Stamp Pattern
// ============================================================================
// The BJT stamps into:
//   RC branch: C -- C'
//   RB branch: B -- B'
//   RE branch: E -- E'
//   Intrinsic transistor: B', C', E'
//   Substrate diode: S, C'

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================
// Charges are on B', C', E', S nodes

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // RC thermal noise: C -- C'
    .{ .row = @intFromEnum(U.c), .col = @intFromEnum(U.c_prime), .kind = .thermal },
    // RB thermal noise: B -- B'
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.b_prime), .kind = .thermal },
    // RE thermal noise: E -- E'
    .{ .row = @intFromEnum(U.e), .col = @intFromEnum(U.e_prime), .kind = .thermal },
    // IC shot noise: C' -- E'
    .{ .row = @intFromEnum(U.c_prime), .col = @intFromEnum(U.e_prime), .kind = .shot },
    // IB shot noise: B' -- E'
    .{ .row = @intFromEnum(U.b_prime), .col = @intFromEnum(U.e_prime), .kind = .shot },
    // 1/f flicker noise: B' -- E'
    .{ .row = @intFromEnum(U.b_prime), .col = @intFromEnum(U.e_prime), .kind = .flicker },
};

// ============================================================================
// Temperature Helper (x-independent; pure f64)
// ============================================================================

/// Thermal voltage from model + instance temperature settings.
/// T_dev = TEMP + 273.15 if TEMP given (non-zero), else TNOM + 273.15 + DTEMP
fn thermalVoltage(model: *const Model, instance: *const Instance) f64 {
    const tnom: f64 = @as(f64, model.tnom);
    const inst_temp: f64 = @as(f64, instance.temp);
    const inst_dtemp: f64 = @as(f64, instance.dtemp);
    const t_dev: f64 = if (inst_temp != 0.0) inst_temp + 273.15 else tnom + 273.15 + inst_dtemp;
    return 8.617333262145e-5 * t_dev;
}

// ============================================================================
// Prep struct: x-independent derived values for eval
// ============================================================================

const EvalPrep = struct {
    type_f: f64,
    is_val: f64,
    bf: f64,
    nf: f64,
    br: f64,
    nr: f64,
    ise: f64,
    ne: f64,
    isc: f64,
    nc: f64,
    vaf: f64,
    var_: f64,
    ikf: f64,
    ikr: f64,
    nkf: f64,
    rb_val: f64,
    rbm_eff: f64,
    irb_val: f64,
    iss_val: f64,
    ns: f64,
    area: f64,
    m_mult: f64,
    vt: f64,
    // Derived conductances
    inv_nf_vt: f64,
    inv_nr_vt: f64,
    inv_ne_vt: f64,
    inv_nc_vt: f64,
    inv_ns_vt: f64,
    area_m: f64,
    g_c: f64,
    g_e: f64,
    rb_is_zero: bool,
    rb_eq_rbm: bool,
    is_half: bool,
};

fn evalPrep(model: *const Model, instance: *const Instance) EvalPrep {
    const type_f: f64 = @floatFromInt(model.type_);
    const is_val: f64 = @as(f64, model.is);
    const nf: f64 = @as(f64, model.nf);
    const nr: f64 = @as(f64, model.nr);
    const ne: f64 = @as(f64, model.ne);
    const nc: f64 = @as(f64, model.nc);
    const nkf: f64 = @as(f64, model.nkf);
    const rb_val: f64 = @as(f64, model.rb);
    const rbm: f64 = @as(f64, model.rbm);
    const re_val: f64 = @as(f64, model.re);
    const rc_val: f64 = @as(f64, model.rc);
    const ns: f64 = @as(f64, model.ns);
    const area: f64 = @as(f64, instance.area);
    const m_mult: f64 = @as(f64, instance.m);
    const vt = thermalVoltage(model, instance);
    const area_m = area * m_mult;
    const rbm_eff: f64 = if (rbm == 0.0) rb_val else rbm;

    return .{
        .type_f = type_f,
        .is_val = is_val,
        .bf = @as(f64, model.bf),
        .nf = nf,
        .br = @as(f64, model.br),
        .nr = nr,
        .ise = @as(f64, model.ise),
        .ne = ne,
        .isc = @as(f64, model.isc),
        .nc = nc,
        .vaf = @as(f64, model.vaf),
        .var_ = @as(f64, model.var_),
        .ikf = @as(f64, model.ikf),
        .ikr = @as(f64, model.ikr),
        .nkf = nkf,
        .rb_val = rb_val,
        .rbm_eff = rbm_eff,
        .irb_val = @as(f64, model.irb),
        .iss_val = @as(f64, model.iss),
        .ns = ns,
        .area = area,
        .m_mult = m_mult,
        .vt = vt,
        .inv_nf_vt = 1.0 / (nf * vt),
        .inv_nr_vt = 1.0 / (nr * vt),
        .inv_ne_vt = 1.0 / (ne * vt),
        .inv_nc_vt = 1.0 / (nc * vt),
        .inv_ns_vt = 1.0 / (ns * vt),
        .area_m = area_m,
        // Collapsed prime nodes (rc/re = 0, see collapse()) carry no tie
        // conductance — a 1e12 short loses real conductances to its ulp.
        .g_c = if (rc_val != 0.0) area_m / rc_val else 0.0,
        .g_e = if (re_val != 0.0) area_m / re_val else 0.0,
        .rb_is_zero = rb_val == 0.0,
        .rb_eq_rbm = @abs(rb_val - rbm_eff) < 1.0e-30,
        .is_half = @abs(nkf - 0.5) < 1.0e-9,
    };
}

// ============================================================================
// Prep struct: x-independent derived values for q
// ============================================================================

const QPrep = struct {
    type_f: f64,
    is_val: f64,
    cje: f64,
    vje: f64,
    mje: f64,
    cjc: f64,
    vjc: f64,
    mjc: f64,
    cjs: f64,
    vjs: f64,
    mjs: f64,
    tf: f64,
    tr: f64,
    fc: f64,
    area_m: f64,
    vt: f64,
    inv_nf_vt: f64,
    inv_nr_vt: f64,
    // B-E depletion derived constants
    fc_vje: f64,
    one_minus_mje: f64,
    q_be_fc: f64,
    f2_be: f64,
    f3_be: f64,
    cje_over_f2_be: f64,
    cje_vje_over_omje: f64,
    mje_over_2vje: f64,
    // B-C depletion derived constants
    fc_vjc: f64,
    one_minus_mjc: f64,
    q_bc_fc: f64,
    f2_bc: f64,
    f3_bc: f64,
    cjc_over_f2_bc: f64,
    cjc_vjc_over_omjc: f64,
    mjc_over_2vjc: f64,
    // Substrate derived constants
    has_sub_cap: bool,
    mjs_is_zero: bool,
    fc_vjs: f64,
    one_minus_mjs: f64,
    cjs_vjs_over_omjs: f64,
    q_sub_fc: f64,
    c_sub_fc: f64,
};

fn qPrep(model: *const Model, instance: *const Instance) QPrep {
    const type_f: f64 = @floatFromInt(model.type_);
    const is_val: f64 = @as(f64, model.is);
    const cje: f64 = @as(f64, model.cje);
    const vje: f64 = @as(f64, model.vje);
    const mje: f64 = @as(f64, model.mje);
    const cjc: f64 = @as(f64, model.cjc);
    const vjc: f64 = @as(f64, model.vjc);
    const mjc: f64 = @as(f64, model.mjc);
    const cjs: f64 = @as(f64, model.cjs);
    const vjs: f64 = @as(f64, model.vjs);
    const mjs: f64 = @as(f64, model.mjs);
    const tf: f64 = @as(f64, model.tf);
    const tr: f64 = @as(f64, model.tr);
    const fc: f64 = @as(f64, model.fc);
    const nf: f64 = @as(f64, model.nf);
    const nr: f64 = @as(f64, model.nr);
    const area: f64 = @as(f64, instance.area);
    const m_mult: f64 = @as(f64, instance.m);
    const vt = thermalVoltage(model, instance);
    const area_m = area * m_mult;
    const one_minus_fc = 1.0 - fc;

    // B-E depletion constants
    const one_minus_mje = 1.0 - mje;
    const fc_vje = fc * vje;
    const q_be_fc = (cje * vje / one_minus_mje) * (1.0 - contract.fmath.exp(one_minus_mje * contract.fmath.log(one_minus_fc)));
    const f2_be = contract.fmath.exp((1.0 + mje) * contract.fmath.log(one_minus_fc));
    const f3_be = 1.0 - fc * (1.0 + mje);

    // B-C depletion constants
    const one_minus_mjc = 1.0 - mjc;
    const fc_vjc = fc * vjc;
    const q_bc_fc = (cjc * vjc / one_minus_mjc) * (1.0 - contract.fmath.exp(one_minus_mjc * contract.fmath.log(one_minus_fc)));
    const f2_bc = contract.fmath.exp((1.0 + mjc) * contract.fmath.log(one_minus_fc));
    const f3_bc = 1.0 - fc * (1.0 + mjc);

    // Substrate constants
    const one_minus_mjs = 1.0 - mjs;
    const fc_vjs = fc * vjs;

    return .{
        .type_f = type_f,
        .is_val = is_val,
        .cje = cje,
        .vje = vje,
        .mje = mje,
        .cjc = cjc,
        .vjc = vjc,
        .mjc = mjc,
        .cjs = cjs,
        .vjs = vjs,
        .mjs = mjs,
        .tf = tf,
        .tr = tr,
        .fc = fc,
        .area_m = area_m,
        .vt = vt,
        .inv_nf_vt = 1.0 / (nf * vt),
        .inv_nr_vt = 1.0 / (nr * vt),
        .fc_vje = fc_vje,
        .one_minus_mje = one_minus_mje,
        .q_be_fc = q_be_fc,
        .f2_be = f2_be,
        .f3_be = f3_be,
        .cje_over_f2_be = cje / f2_be,
        .cje_vje_over_omje = cje * vje / one_minus_mje,
        .mje_over_2vje = mje / (2.0 * vje),
        .fc_vjc = fc_vjc,
        .one_minus_mjc = one_minus_mjc,
        .q_bc_fc = q_bc_fc,
        .f2_bc = f2_bc,
        .f3_bc = f3_bc,
        .cjc_over_f2_bc = cjc / f2_bc,
        .cjc_vjc_over_omjc = cjc * vjc / one_minus_mjc,
        .mjc_over_2vjc = mjc / (2.0 * vjc),
        .has_sub_cap = cjs > 0.0,
        .mjs_is_zero = @abs(mjs) < 1.0e-30,
        .fc_vjs = fc_vjs,
        .one_minus_mjs = one_minus_mjs,
        .cjs_vjs_over_omjs = cjs * vjs / one_minus_mjs,
        .q_sub_fc = (cjs * vjs / one_minus_mjs) * (1.0 - contract.fmath.exp(one_minus_mjs * contract.fmath.log(one_minus_fc))),
        .c_sub_fc = cjs / contract.fmath.exp(mjs * contract.fmath.log(one_minus_fc)),
    };
}

// ============================================================================
// PrepCache: combined eval + q prep
// ============================================================================

pub const PrepCache = struct { dc: EvalPrep, q: QPrep };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return .{ .dc = evalPrep(model, instance), .q = qPrep(model, instance) };
}

// ============================================================================
// DC Current Function (eval)
// ============================================================================
// Value-form: generic over scalar S. Everything x-independent (parameter
// casts, temperature, conductance constants) stays f64; the x-dependent
// current chains use S ops so the solver's derivative scalar sees them.

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;

    const c = @intFromEnum(U.c);
    const b = @intFromEnum(U.b);
    const e = @intFromEnum(U.e);
    const s = @intFromEnum(U.s);
    const cp = @intFromEnum(U.c_prime);
    const bp = @intFromEnum(U.b_prime);
    const ep = @intFromEnum(U.e_prime);

    const p = &pc.dc;

    // --- Constants ---
    const gmin: f64 = 1.0e-12;

    // --- Junction voltages (NPN convention) ---
    const v_be = x[bp].sub(x[ep]).scale(p.type_f);
    const v_bc = x[bp].sub(x[cp]).scale(p.type_f);

    // =======================================================================
    // Forward and Reverse Diode Currents
    // =======================================================================
    const arg_be = v_be.scale(p.inv_nf_vt).minC(80.0);
    const c_be = arg_be.exp().addC(-1.0).scale(p.is_val);

    const arg_bc = v_bc.scale(p.inv_nr_vt).minC(80.0);
    const c_bc = arg_bc.exp().addC(-1.0).scale(p.is_val);

    // =======================================================================
    // Base-Emitter Leakage Current
    // =======================================================================
    const arg_be_leak = v_be.scale(p.inv_ne_vt).minC(80.0);
    const i_be_leak = arg_be_leak.exp().addC(-1.0).scale(p.ise);

    // =======================================================================
    // Base-Collector Leakage Current
    // =======================================================================
    const arg_bc_leak = v_bc.scale(p.inv_nc_vt).minC(80.0);
    const i_bc_leak = arg_bc_leak.exp().addC(-1.0).scale(p.isc);

    // =======================================================================
    // Base Charge Factor (Early Effect + High Injection)
    // =======================================================================
    // Early effect reciprocal base charge
    const early_be: S = if (p.var_ > 0.0) v_be.scale(1.0 / p.var_) else S.con(0.0);
    const early_bc: S = if (p.vaf > 0.0) v_bc.scale(1.0 / p.vaf) else S.con(0.0);
    const q1_denom = early_bc.add(early_be).neg().addC(1.0);
    const q1 = S.con(1.0).div(q1_denom.maxC(1.0e-30));

    // High-injection base charge
    const hi_be: S = if (p.ikf > 0.0) c_be.scale(1.0 / p.ikf) else S.con(0.0);
    const hi_bc: S = if (p.ikr > 0.0) c_bc.scale(1.0 / p.ikr) else S.con(0.0);
    const q2 = hi_be.add(hi_bc);

    // Normalized base charge
    const sq_arg = q2.scale(4.0).addC(1.0).maxC(0.0);
    const sqarg_val: S = if (p.is_half) sq_arg.sqrt() else sq_arg.maxC(1.0e-30).log().scale(p.nkf).exp();
    const q_b = q1.mul(sqarg_val.addC(1.0)).scale(0.5);

    // =======================================================================
    // Transport Current
    // =======================================================================
    const i_cc = c_be.sub(c_bc).div(q_b.maxC(1.0e-30));

    // =======================================================================
    // Ideal Base Currents
    // =======================================================================
    const i_be_ideal = c_be.scale(1.0 / p.bf);
    const i_bc_ideal = c_bc.scale(1.0 / p.br);

    // =======================================================================
    // Terminal Currents (Intrinsic) with GMIN Convergence Aid
    // =======================================================================
    const i_c_int = i_cc.sub(i_bc_ideal).sub(i_bc_leak).sub(v_bc.scale(gmin));
    const i_b_int = i_be_ideal.add(i_be_leak).add(i_bc_ideal).add(i_bc_leak)
        .add(v_be.scale(gmin)).add(v_bc.scale(gmin));

    // =======================================================================
    // Area and Multiplier Scaling
    // =======================================================================
    const i_c_scaled = i_c_int.scale(p.area_m);
    const i_b_scaled = i_b_int.scale(p.area_m);

    // =======================================================================
    // Parasitic Resistance Currents
    // =======================================================================
    // Collector resistance
    const i_rc = x[c].sub(x[cp]).scale(p.g_c);

    // Emitter resistance
    const i_re = x[e].sub(x[ep]).scale(p.g_e);

    // =======================================================================
    // Base Resistance (Four cases)
    // =======================================================================
    const v_bb = x[b].sub(x[bp]);

    // Case 1: RB = 0 (no base resistance) => GSHORT
    // Case 2: Constant base resistance (RBM == RB or IRB == 0 and RBM == RB)
    // Case 3: qb-dependent base resistance (IRB == 0, RBM != RB)
    // Case 4: Current-dependent base resistance (IRB != 0)
    // Case selection depends only on parameters; cases 3/4 depend on x
    // through q_b / |i_b| so those chains stay in S.

    var i_rb: S = undefined;
    if (p.rb_is_zero) {
        // b_prime collapsed onto b: no tie current (1e12 ulp poison).
        i_rb = S.con(0.0);
    } else if (p.irb_val > 0.0) {
        // Case 4: R_B_eff = RBM/AREA + (RB - RBM) / (AREA * (1 + sqrt(|IB|*AREA*M/IRB + 1e-9)))
        const abs_ib = i_b_int.abs().scale(p.area_m);
        const rb_case4_denom = abs_ib.scale(1.0 / @max(p.irb_val, 1.0e-30)).addC(1.0e-9).sqrt().addC(1.0);
        const rb_case4 = S.con(p.rb_val - p.rbm_eff).div(rb_case4_denom.scale(p.area)).addC(p.rbm_eff / p.area);
        const g_b_case4 = S.con(p.m_mult).div(rb_case4.maxC(1.0e-30));
        i_rb = v_bb.mul(g_b_case4);
    } else if (p.rb_eq_rbm) {
        // Case 2: constant R_B
        const g_b_case2 = p.area_m / @max(p.rb_val, 1.0e-30);
        i_rb = v_bb.scale(g_b_case2);
    } else {
        // Case 3: R_B_eff = RBM/AREA + (RB - RBM) / (AREA * qb)
        const rb_case3 = S.con(p.rb_val - p.rbm_eff).div(q_b.maxC(1.0e-30).scale(p.area)).addC(p.rbm_eff / p.area);
        const g_b_case3 = S.con(p.m_mult).div(rb_case3.maxC(1.0e-30));
        i_rb = v_bb.mul(g_b_case3);
    }

    // =======================================================================
    // Substrate Diode Current
    // =======================================================================
    const v_sub = x[s].sub(x[cp]).scale(p.type_f);
    const arg_sub = v_sub.scale(p.inv_ns_vt).minC(80.0);
    const i_sub_raw = arg_sub.exp().addC(-1.0).scale(p.iss_val * p.area_m);
    const i_sub: S = if (p.iss_val > 0.0) i_sub_raw else S.con(0.0);

    // =======================================================================
    // KCL Node Stamps
    // =======================================================================
    // Convention: out[u] = current LEAVING node u through the device
    // (same as resistor/diode). NPN active: collector draws i_c from c,
    // emitter emits i_c+i_b into e.
    var out: [n_u]S = undefined;
    out[c] = i_rc;
    out[b] = i_rb;
    out[e] = i_re;
    out[s] = i_sub.scale(p.type_f);
    out[cp] = i_c_scaled.scale(p.type_f).sub(i_rc).sub(i_sub.scale(p.type_f));
    out[bp] = i_b_scaled.scale(p.type_f).sub(i_rb);
    out[ep] = i_re.add(i_c_scaled.add(i_b_scaled).scale(p.type_f)).neg();
    return out;
}

// ============================================================================
// Charge Function (q)
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;

    const c = @intFromEnum(U.c);
    const b = @intFromEnum(U.b);
    const e = @intFromEnum(U.e);
    const s = @intFromEnum(U.s);
    const cp = @intFromEnum(U.c_prime);
    const bp = @intFromEnum(U.b_prime);
    const ep = @intFromEnum(U.e_prime);

    const p = &pc.q;

    // --- Junction voltages (NPN convention) ---
    const v_be = x[bp].sub(x[ep]).scale(p.type_f);
    const v_bc = x[bp].sub(x[cp]).scale(p.type_f);

    // ===================================================================
    // B-E Depletion Charge (CJE != 0)
    // ===================================================================

    // Reverse/moderate forward bias: v_be < FC * VJE
    const x_be_dep = v_be.scale(-1.0 / p.vje).addC(1.0).maxC(1.0e-30);
    const q_be_dep = x_be_dep.log().scale(p.one_minus_mje).exp().neg().addC(1.0).scale(p.cje_vje_over_omje);

    // Strong forward bias: v_be >= FC * VJE (quadratic extension)
    const q_be_fwd = v_be.addC(-p.fc_vje).scale(p.f3_be)
        .add(v_be.mul(v_be).addC(-(p.fc_vje * p.fc_vje)).scale(p.mje_over_2vje))
        .scale(p.cje_over_f2_be).addC(p.q_be_fc);

    // Region select on voltage (same branch as the original piecewise form)
    const q_be_depl: S = if (v_be.val() < p.fc_vje) q_be_dep else q_be_fwd;

    // ===================================================================
    // B-E Diffusion Charge (Forward Transit Time, TF != 0)
    // ===================================================================
    const arg_be_diff = v_be.scale(p.inv_nf_vt).minC(80.0);
    const q_be_diff = arg_be_diff.exp().addC(-1.0).scale(p.tf * p.is_val);

    // ===================================================================
    // Total B-E Charge
    // ===================================================================
    const q_be = q_be_depl.add(q_be_diff).scale(p.area_m);

    // ===================================================================
    // B-C Depletion Charge (CJC != 0)
    // ===================================================================

    // Reverse/moderate forward bias: v_bc < FC * VJC
    const x_bc_dep = v_bc.scale(-1.0 / p.vjc).addC(1.0).maxC(1.0e-30);
    const q_bc_dep = x_bc_dep.log().scale(p.one_minus_mjc).exp().neg().addC(1.0).scale(p.cjc_vjc_over_omjc);

    // Strong forward bias: v_bc >= FC * VJC (quadratic extension)
    const q_bc_fwd = v_bc.addC(-p.fc_vjc).scale(p.f3_bc)
        .add(v_bc.mul(v_bc).addC(-(p.fc_vjc * p.fc_vjc)).scale(p.mjc_over_2vjc))
        .scale(p.cjc_over_f2_bc).addC(p.q_bc_fc);

    // Region select on voltage (same branch as the original piecewise form)
    const q_bc_depl: S = if (v_bc.val() < p.fc_vjc) q_bc_dep else q_bc_fwd;

    // ===================================================================
    // B-C Diffusion Charge (Reverse Transit Time, TR != 0)
    // ===================================================================
    const arg_bc_diff = v_bc.scale(p.inv_nr_vt).minC(80.0);
    const q_bc_diff = arg_bc_diff.exp().addC(-1.0).scale(p.tr * p.is_val);

    // ===================================================================
    // Total B-C Charge
    // ===================================================================
    const q_bc = q_bc_depl.add(q_bc_diff).scale(p.area_m);

    // ===================================================================
    // Substrate Junction Charge (CJS != 0)
    // ===================================================================
    const v_sub = x[s].sub(x[cp]).scale(p.type_f);

    // When mjs = 0 (linear capacitance): Q_sub = CJS * V_sub
    const q_sub_linear = v_sub.scale(p.cjs);

    // When mjs != 0 (graded junction):

    // Reverse/moderate forward bias: v_sub < FC * VJS
    const x_sub_dep = v_sub.scale(-1.0 / p.vjs).addC(1.0).maxC(1.0e-30);
    const q_sub_dep = x_sub_dep.log().scale(p.one_minus_mjs).exp().neg().addC(1.0).scale(p.cjs_vjs_over_omjs);

    // Strong forward bias: v_sub >= FC * VJS
    const q_sub_fwd = v_sub.addC(-p.fc_vjs).scale(p.c_sub_fc).addC(p.q_sub_fc);

    // Region select on voltage (same branch as the original piecewise form)
    const q_sub_graded: S = if (v_sub.val() < p.fc_vjs) q_sub_dep else q_sub_fwd;

    // Select based on mjs (parameter-only)
    const q_sub_raw: S = if (p.mjs_is_zero) q_sub_linear else q_sub_graded;
    const q_sub: S = if (p.has_sub_cap) q_sub_raw.scale(p.area_m) else S.con(0.0);

    // ===================================================================
    // Charge KCL Stamps
    // ===================================================================
    // Same leaving convention as eval(): + plate of Q_BE/Q_BC at B',
    // − plates at E'/C'; + plate of Q_sub at S (v_sub = (S − C')·type),
    // − plate at C'.
    var out: [n_u]S = undefined;
    out[c] = S.con(0.0);
    out[b] = S.con(0.0);
    out[e] = S.con(0.0);
    out[bp] = q_be.add(q_bc).scale(p.type_f);
    out[ep] = q_be.scale(-p.type_f);
    out[cp] = q_bc.add(q_sub).scale(-p.type_f);
    out[s] = q_sub.scale(p.type_f);
    return out;
}

// ============================================================================
// Voltage Limiting (DEVpnjlim for B-E and B-C junctions)
// ============================================================================

/// pnjlim writes its junction correction to b_prime (ngspice icheck source).
pub const limit_flag_unknowns = [_]U{.b_prime};

pub fn limit(model: *const Model, instance: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const cp = @intFromEnum(U.c_prime);
    const bp = @intFromEnum(U.b_prime);
    const ep = @intFromEnum(U.e_prime);

    const is_val: f64 = @as(f64, model.is);
    const tnom: f64 = @as(f64, model.tnom);
    const type_f: f64 = @floatFromInt(model.type_);
    const inst_temp: f64 = @as(f64, instance.temp);
    const inst_dtemp: f64 = @as(f64, instance.dtemp);
    const t_dev: f64 = if (inst_temp != 0.0) inst_temp + 273.15 else tnom + 273.15 + inst_dtemp;
    const vt: f64 = 8.617333262145e-5 * t_dev;

    // Critical voltage
    const v_crit = vt * contract.fmath.log(vt / (@sqrt(2.0) * is_val));

    var result = x_new;

    // ===================================================================
    // Limit V_BE first (adjusting B' node)
    // ===================================================================
    const vbe_new = (result[bp] - result[ep]) * type_f;
    const vbe_old = (x_old[bp] - x_old[ep]) * type_f;

    var vbe_limited = vbe_new;

    if (vbe_new > v_crit and @abs(vbe_new - vbe_old) > 2.0 * vt) {
        if (vbe_old > 0.0) {
            const ratio = 1.0 + (vbe_new - vbe_old) / vt;
            if (ratio > 2.0) {
                vbe_limited = vbe_old + vt * contract.fmath.log(ratio);
            } else {
                vbe_limited = v_crit;
            }
        } else {
            if (vbe_new / vt > 0.0) {
                vbe_limited = vt * contract.fmath.log(vbe_new / vt);
            } else {
                vbe_limited = v_crit;
            }
        }
    }

    // Apply correction to B' via the type factor
    const delta_be = (vbe_limited - vbe_new) * type_f;
    result[bp] = result[bp] + delta_be;

    // ===================================================================
    // Limit V_BC using the already-adjusted B' node
    // ===================================================================
    const vbc_new = (result[bp] - result[cp]) * type_f;
    const vbc_old = (x_old[bp] - x_old[cp]) * type_f;

    var vbc_limited = vbc_new;

    if (vbc_new > v_crit and @abs(vbc_new - vbc_old) > 2.0 * vt) {
        if (vbc_old > 0.0) {
            const ratio = 1.0 + (vbc_new - vbc_old) / vt;
            if (ratio > 2.0) {
                vbc_limited = vbc_old + vt * contract.fmath.log(ratio);
            } else {
                vbc_limited = v_crit;
            }
        } else {
            if (vbc_new / vt > 0.0) {
                vbc_limited = vt * contract.fmath.log(vbc_new / vt);
            } else {
                vbc_limited = v_crit;
            }
        }
    }

    // Apply correction to B' via the type factor
    const delta_bc = (vbc_limited - vbc_new) * type_f;
    result[bp] = result[bp] + delta_bc;

    return result;
}

// ============================================================================
// Node Collapse (ngspice BJTsetup: prime = port when parasitic R = 0)
// ============================================================================

pub fn collapse(model: *const Model, _: *const Instance) [n_u]?u8 {
    var out: [n_u]?u8 = @splat(null);
    if (model.rc == 0) out[@intFromEnum(U.c_prime)] = @intFromEnum(U.c);
    if (model.rb == 0) out[@intFromEnum(U.b_prime)] = @intFromEnum(U.b);
    if (model.re == 0) out[@intFromEnum(U.e_prime)] = @intFromEnum(U.e);
    return out;
}

// ============================================================================
// Cold-Start Seeding (SPICE MODEINITJCT)
// ============================================================================
// bjtload.c: at MODEINITJCT vbe = vcrit, vbc = 0. Node-write equivalent on a
// zeroed x (e' = 0): b' = type·vcrit, c' = b' (so vbc = 0).

pub fn seed(model: *const Model, instance: *const Instance) [n_u]?f64 {
    const is_val: f64 = @as(f64, model.is);
    const tnom: f64 = @as(f64, model.tnom);
    const type_f: f64 = @floatFromInt(model.type_);
    const inst_temp: f64 = @as(f64, instance.temp);
    const inst_dtemp: f64 = @as(f64, instance.dtemp);
    const t_dev: f64 = if (inst_temp != 0.0) inst_temp + 273.15 else tnom + 273.15 + inst_dtemp;
    const vt: f64 = 8.617333262145e-5 * t_dev;
    const v_crit = vt * contract.fmath.log(vt / (@sqrt(2.0) * is_val));
    var out: [n_u]?f64 = @splat(null);
    out[@intFromEnum(U.b_prime)] = type_f * v_crit;
    out[@intFromEnum(U.c_prime)] = type_f * v_crit;
    return out;
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

test "bjt: NPN forward-active residual (default model)" {
    // Hand-computed from the old i() formula, default Model/Instance:
    //   nodes: c=1.65 b=0.65 e=0 s=0 c'=1.65 b'=0.65 e'=0
    //   t_dev = 27 + 273.15 = 300.15 K
    //   vt    = 8.617333262145e-5 * 300.15 = 0.025864925786328215
    //   v_be  = 0.65, v_bc = -1.0
    //   c_be  = is*(exp(0.65/vt)-1)  = 8.204693798404185e-6   (is = f32(1e-16))
    //   c_bc  = is*(exp(-1.0/vt)-1)  = -1.0000000168623835e-16
    //   q_b   = 1 (vaf=var=ikf=ikr=0, nkf=0.5 -> sqrt(1)=1)
    //   i_c   = (c_be-c_bc) - c_bc/br - gmin*(-1.0) = 8.204694798604186e-6
    //   i_b   = c_be/100 + c_bc + gmin*0.65 + gmin*(-1.0) = 8.204658788404186e-8
    //   rb=rc=re=0 and V(c)=V(c'), V(b)=V(b'), V(e)=V(e') -> parasitic
    //   currents are 0; iss=0 -> i_sub=0.
    //   Leaving convention: out[c']=i_c (collector draws), out[b']=i_b,
    //   out[e']=-(i_c+i_b) (emitter emits), rest 0.
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.65, 0.65, 0.0, 0.0, 1.65, 0.65, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.c)], 1e-30);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.b)], 1e-30);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.e)], 1e-30);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.s)], 1e-30);
    try testing.expectApproxEqRel(@as(f64, 8.204694798604186e-6), out[@intFromEnum(U.c_prime)], 1e-9);
    try testing.expectApproxEqRel(@as(f64, 8.204658788404186e-8), out[@intFromEnum(U.b_prime)], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -8.286741386488227e-6), out[@intFromEnum(U.e_prime)], 1e-9);
}

test "bjt: PNP polarity flips residual sign" {
    // Same bias mirrored: nodes c=-1.65 b=-0.65 e=0 s=0 c'=-1.65 b'=-0.65 e'=0
    // with type=-1 gives v_be = (b'-e')*(-1) = 0.65, identical internal
    // physics, and out[c'] = +i_c*type = -8.204694798604186e-6.
    const model: Model = .{ .type_ = -1 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ -1.65, -0.65, 0.0, 0.0, -1.65, -0.65, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqRel(@as(f64, -8.204694798604186e-6), out[@intFromEnum(U.c_prime)], 1e-9);
}

test "bjt: constant base resistance (case 2)" {
    // rb=100 (rbm=0 -> rbm_eff=rb -> constant case): g_b = area*m/rb = 0.01.
    // v_bb = V(b) - V(b') = 0.75 - 0.65 = 0.09999999999999998 (f64)
    // i_rb = v_bb * 0.01 = 9.999999999999998e-4; out[b] = +i_rb (leaving b).
    const model: Model = .{ .rb = 100.0 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.65, 0.75, 0.0, 0.0, 1.65, 0.65, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqRel(@as(f64, 9.999999999999998e-4), out[@intFromEnum(U.b)], 1e-12);
}

test "bjt: charges (depletion + diffusion + linear substrate)" {
    // Hand-computed from the old q() formula with cje=1e-12, cjc=2e-12,
    // cjs=1e-12, tf=1e-9 (all f32-rounded), remaining defaults
    // (vje=vjc=0.75, mje=mjc=f32(0.33), fc=0.5, mjs=0, tr=0):
    //   nodes: c=1.65 b=0.65 e=0 s=0 c'=1.65 b'=0.65 e'=0
    //   v_be = 0.65 >= fc*vje = 0.375 -> quadratic extension:
    //     q_be_fc  = (cje*vje/(1-mje))*(1-exp((1-mje)*ln(0.5)))
    //     f2 = exp((1+mje)*ln 0.5), f3 = 1-0.5*(1+mje)
    //     q_be_fwd = q_be_fc + (cje/f2)*(f3*(0.65-0.375)
    //                + (mje/1.5)*(0.65^2-0.375^2)) = 5.99461e-13
    //     q_be_diff = tf*is*(exp(0.65/vt)-1) = 8.20469e-13*... = 8.204695e-13*tf
    //                = 8.2046939...e-6*1e-9 = 8.204694e-15... totalled:
    //     q_be = q_be_fwd + q_be_diff = 8.115612185307454e-13
    //   v_bc = -1.0 < 0.375 -> depletion branch:
    //     q_bc = (cjc*vjc/(1-mjc))*(1-exp((1-mjc)*ln(1+1/0.75)))
    //          = -1.710864842226113e-12
    //   v_sub = -1.65, mjs=0 -> linear: q_sub = cjs*(-1.65)
    //          = -1.6499999934069253e-12
    //   out[b'] = q_be+q_bc    = -8.993036236953676e-13
    //   out[e'] = -q_be        = -8.115612185307454e-13
    //   out[c'] = -(q_bc+q_sub) = 3.3608648356330383e-12
    //   out[s]  = q_sub        = -1.6499999934069253e-12
    const model: Model = .{ .cje = 1e-12, .cjc = 2e-12, .cjs = 1e-12, .tf = 1e-9 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 1.65, 0.65, 0.0, 0.0, 1.65, 0.65, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.c)], 1e-30);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.b)], 1e-30);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.e)], 1e-30);
    try testing.expectApproxEqRel(@as(f64, -8.993036236953676e-13), out[@intFromEnum(U.b_prime)], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -8.115612185307454e-13), out[@intFromEnum(U.e_prime)], 1e-9);
    try testing.expectApproxEqRel(@as(f64, 3.3608648356330383e-12), out[@intFromEnum(U.c_prime)], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -1.6499999934069253e-12), out[@intFromEnum(U.s)], 1e-9);
}
