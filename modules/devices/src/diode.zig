const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: p (anode) -- RS -- p' (internal anode) -- [junction] -- n (cathode)
// ============================================================================

pub const U = enum(u8) { p, n, p_prime };
pub const num_ports: usize = 2;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Core DC ---
    level: i32 = 1,
    is: f32 = 1e-14,
    jsw: f32 = 0,
    n: f32 = 1,
    ns: f32 = 1,
    rs: f32 = 0,
    cond: f32 = 0,
    ikf: f32 = 0,
    ikr: f32 = 0,

    // --- Recombination ---
    isr: f32 = 0,
    nr: f32 = 2,

    // --- Breakdown ---
    bv: f32 = 0,
    ibv: f32 = 1e-3,
    nbv: f32 = 1,

    // --- Junction Capacitance (Bottom) ---
    cjo: f32 = 0,
    vj: f32 = 1,
    m: f32 = 0.5,
    fc: f32 = 0.5,

    // --- Junction Capacitance (Sidewall) ---
    cjp: f32 = 0,
    php: f32 = 1,
    mjsw: f32 = 0.33,
    fcs: f32 = 0.5,

    // --- Transit Time ---
    tt: f32 = 0,
    ttt1: f32 = 0,
    ttt2: f32 = 0,

    // --- Temperature ---
    tnom: f32 = 27,
    tlev: i32 = 0,
    tlevc: i32 = 0,
    eg: f32 = 1.11,
    gap1: f32 = 7.02e-4,
    gap2: f32 = 1108,
    xti: f32 = 3,
    trs: f32 = 0,
    trs2: f32 = 0,
    tm1: f32 = 0,
    tm2: f32 = 0,
    cta: f32 = 0,
    ctp: f32 = 0,
    tpb: f32 = 0,
    tphp: f32 = 0,
    tcv: f32 = 0,

    // --- Tunneling ---
    jtun: f32 = 0,
    jtunsw: f32 = 0,
    ntun: f32 = 30,
    xtitun: f32 = 3,
    keg: f32 = 1,

    // --- Noise ---
    kf: f32 = 0,
    af: f32 = 1,

    // --- Self-Heating ---
    rth0: f32 = 0,
    cth0: f32 = 1e-5,

    // --- Absolute Maximum Ratings ---
    fv_max: f32 = 1e30,
    bv_max: f32 = 1e30,
    id_max: f32 = 1e30,
    te_max: f32 = 1e30,
    pd_max: f32 = 1e30,

    // --- Geometry Level 3 (Metal/Poly Capacitor) ---
    lm: f32 = 0,
    lp: f32 = 0,
    wm: f32 = 0,
    wp: f32 = 0,
    xom: f32 = 1e-6,
    xoi: f32 = 1e-6,
    xm: f32 = 0,
    xp: f32 = 0,
    xw: f32 = 0,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    area: f32 = 1,
    pj: f32 = 0,
    m_mult: f32 = 1,
    w: f32 = 0,
    l: f32 = 0,
    temp: f32 = -1,
    dtemp: f32 = 0,
};

// ============================================================================
// Sparse Conductance Stamp Pattern
// ============================================================================
// The diode stamps into:
//   p,p  p,p'  p',p  p',p'  (series resistance)
//   p',p'  p',n  n,p'  n,n   (junction)
// Combined unique entries:

pub const g_pattern_override = [_]contract.Entry(n_u){
    // RS branch: p -- p'
    .{ .row = @intFromEnum(U.p), .col = @intFromEnum(U.p) },
    .{ .row = @intFromEnum(U.p), .col = @intFromEnum(U.p_prime) },
    .{ .row = @intFromEnum(U.p_prime), .col = @intFromEnum(U.p) },
    // Junction branch: p' -- n
    .{ .row = @intFromEnum(U.p_prime), .col = @intFromEnum(U.p_prime) },
    .{ .row = @intFromEnum(U.p_prime), .col = @intFromEnum(U.n) },
    .{ .row = @intFromEnum(U.n), .col = @intFromEnum(U.p_prime) },
    .{ .row = @intFromEnum(U.n), .col = @intFromEnum(U.n) },
};

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================
// Charge is on p' and n only (junction capacitance).

pub const c_pattern_override = [_]contract.Entry(n_u){
    .{ .row = @intFromEnum(U.p_prime), .col = @intFromEnum(U.p_prime) },
    .{ .row = @intFromEnum(U.p_prime), .col = @intFromEnum(U.n) },
    .{ .row = @intFromEnum(U.n), .col = @intFromEnum(U.p_prime) },
    .{ .row = @intFromEnum(U.n), .col = @intFromEnum(U.n) },
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Shot noise across junction (p' -- n)
    .{ .row = @intFromEnum(U.p_prime), .col = @intFromEnum(U.n), .kind = .shot },
    // Flicker noise across junction (p' -- n)
    .{ .row = @intFromEnum(U.p_prime), .col = @intFromEnum(U.n), .kind = .flicker },
    // Thermal noise across series resistance (p -- p')
    .{ .row = @intFromEnum(U.p), .col = @intFromEnum(U.p_prime), .kind = .thermal },
};

// ============================================================================
// Prep struct: x-independent derived values for eval
// ============================================================================

const EvalPrep = struct {
    is_val: f64,
    isr: f64,
    jsw_pj: f64,
    jtun_area: f64,
    jtunsw_pj: f64,
    cond: f64,
    bv: f64,
    ibv_val: f64,
    ikf: f64,
    ikr: f64,
    area_m: f64,
    g_rs: f64,
    // Reciprocal emission-voltage products
    inv_n_vt: f64,
    inv_nr_vt: f64,
    inv_ns_vt: f64,
    inv_ntun_vt: f64,
    inv_nbv_vt: f64,
    deep_rev_thresh: f64,
};

fn evalPrep(model: *const Model, instance: *const Instance) EvalPrep {
    const is_val: f64 = @as(f64, model.is);
    const n_em: f64 = @as(f64, model.n);
    const ns: f64 = @as(f64, model.ns);
    const rs: f64 = @as(f64, model.rs);
    const nr: f64 = @as(f64, model.nr);
    const nbv: f64 = @as(f64, model.nbv);
    const ntun: f64 = @as(f64, model.ntun);
    const tnom: f64 = @as(f64, model.tnom);
    const area: f64 = @as(f64, instance.area);
    const pj: f64 = @as(f64, instance.pj);
    const m_mult: f64 = @as(f64, instance.m_mult);
    const vt: f64 = 8.617333e-5 * (tnom + 273.15);
    const area_m = area * m_mult;

    return .{
        .is_val = is_val,
        .isr = @as(f64, model.isr),
        .jsw_pj = @as(f64, model.jsw) * pj,
        .jtun_area = @as(f64, model.jtun) * area,
        .jtunsw_pj = @as(f64, model.jtunsw) * pj,
        .cond = @as(f64, model.cond),
        .bv = @as(f64, model.bv),
        .ibv_val = @as(f64, model.ibv),
        .ikf = @as(f64, model.ikf),
        .ikr = @as(f64, model.ikr),
        .area_m = area_m,
        // Collapsed p_prime (rs = 0, see collapse()) carries no tie
        // conductance — a 1e12 short absorbs real gd into its ulp (1.22e-4).
        .g_rs = if (rs != 0.0) area_m / rs else 0.0,
        .inv_n_vt = 1.0 / (n_em * vt),
        .inv_nr_vt = 1.0 / (nr * vt),
        .inv_ns_vt = 1.0 / (ns * vt),
        .inv_ntun_vt = 1.0 / (ntun * vt),
        .inv_nbv_vt = 1.0 / (nbv * vt),
        .deep_rev_thresh = -3.0 * n_em * vt,
    };
}

// ============================================================================
// Prep struct: x-independent derived values for q
// ============================================================================

const QPrep = struct {
    is_val: f64,
    cjo: f64,
    vj: f64,
    m_grad: f64,
    fc: f64,
    cjp: f64,
    php: f64,
    mjsw: f64,
    fcs: f64,
    tt: f64,
    area: f64,
    pj: f64,
    m_mult: f64,
    inv_n_vt: f64,
    // Bottom junction derived constants
    fc_vj: f64,
    one_minus_m: f64,
    cjo_vj_over_om: f64,
    // Bottom fwd-bias constants
    f1_bot: f64,
    f2_bot: f64,
    f3_bot: f64,
    cjo_over_f2_bot: f64,
    m_over_2vj: f64,
    // Sidewall derived constants
    fcs_php: f64,
    one_minus_mjsw: f64,
    cjp_pj_php_over_omjsw: f64,
    // Sidewall fwd-bias constants
    f1_sw: f64,
    f2_sw: f64,
    f3_sw: f64,
    cjp_pj_over_f2_sw: f64,
    mjsw_over_2php: f64,
};

fn qPrepFn(model: *const Model, instance: *const Instance) QPrep {
    const is_val: f64 = @as(f64, model.is);
    const n_em: f64 = @as(f64, model.n);
    const cjo: f64 = @as(f64, model.cjo);
    const vj: f64 = @as(f64, model.vj);
    const m_grad: f64 = @as(f64, model.m);
    const fc: f64 = @as(f64, model.fc);
    const cjp: f64 = @as(f64, model.cjp);
    const php: f64 = @as(f64, model.php);
    const mjsw: f64 = @as(f64, model.mjsw);
    const fcs: f64 = @as(f64, model.fcs);
    const tt: f64 = @as(f64, model.tt);
    const tnom: f64 = @as(f64, model.tnom);
    const area: f64 = @as(f64, instance.area);
    const pj: f64 = @as(f64, instance.pj);
    const m_mult: f64 = @as(f64, instance.m_mult);
    const vt: f64 = 8.617333e-5 * (tnom + 273.15);
    const one_minus_fc = 1.0 - fc;

    // Bottom junction constants
    const one_minus_m = 1.0 - m_grad;
    const fc_vj = fc * vj;
    const f1_bot = (cjo * vj / one_minus_m) * (1.0 - contract.fmath.exp(one_minus_m * contract.fmath.log(one_minus_fc)));
    const f2_bot = contract.fmath.exp((1.0 + m_grad) * contract.fmath.log(one_minus_fc));
    const f3_bot = 1.0 - fc * (1.0 + m_grad);

    // Sidewall constants
    const one_minus_mjsw = 1.0 - mjsw;
    const fcs_php = fcs * php;
    const one_minus_fcs = 1.0 - fcs;
    const f1_sw = (cjp * pj * php / one_minus_mjsw) * (1.0 - contract.fmath.exp(one_minus_mjsw * contract.fmath.log(one_minus_fcs)));
    const f2_sw = contract.fmath.exp((1.0 + mjsw) * contract.fmath.log(one_minus_fcs));
    const f3_sw = 1.0 - fcs * (1.0 + mjsw);

    return .{
        .is_val = is_val,
        .cjo = cjo,
        .vj = vj,
        .m_grad = m_grad,
        .fc = fc,
        .cjp = cjp,
        .php = php,
        .mjsw = mjsw,
        .fcs = fcs,
        .tt = tt,
        .area = area,
        .pj = pj,
        .m_mult = m_mult,
        .inv_n_vt = 1.0 / (n_em * vt),
        .fc_vj = fc_vj,
        .one_minus_m = one_minus_m,
        .cjo_vj_over_om = cjo * vj / one_minus_m,
        .f1_bot = f1_bot,
        .f2_bot = f2_bot,
        .f3_bot = f3_bot,
        .cjo_over_f2_bot = cjo / f2_bot,
        .m_over_2vj = m_grad / (2.0 * vj),
        .fcs_php = fcs_php,
        .one_minus_mjsw = one_minus_mjsw,
        .cjp_pj_php_over_omjsw = cjp * pj * php / one_minus_mjsw,
        .f1_sw = f1_sw,
        .f2_sw = f2_sw,
        .f3_sw = f3_sw,
        .cjp_pj_over_f2_sw = cjp * pj / f2_sw,
        .mjsw_over_2php = mjsw / (2.0 * php),
    };
}

// ============================================================================
// PrepCache: combined eval + q prep
// ============================================================================

pub const PrepCache = struct { dc: EvalPrep, q: QPrep };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return .{ .dc = evalPrep(model, instance), .q = qPrepFn(model, instance) };
}

// ============================================================================
// DC Current Function (eval)
// ============================================================================
// Value-form: parameter/temperature preprocessing is plain f64 (x-independent);
// only the chains downstream of the terminal voltages use S ops.

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;

    const p_idx = @intFromEnum(U.p);
    const n_ = @intFromEnum(U.n);
    const pp = @intFromEnum(U.p_prime);

    const p = &pc.dc;

    // --- GMIN ---
    const gmin: f64 = 1.0e-12;

    // --- Junction voltage (x-dependent from here on) ---
    const vd = x[pp].sub(x[n_]);

    // --- Forward/Reverse junction current with deep reverse clamping ---
    const arg_norm = vd.scale(p.inv_n_vt).minC(80.0);
    const id_shockley = arg_norm.exp().addC(-1.0).scale(p.is_val);
    // Region branch on voltage (matches original piecewise physics)
    var id_val: S = if (vd.val() < p.deep_rev_thresh) S.con(-p.is_val) else id_shockley;

    // --- Recombination current ---
    const arg_rec = vd.scale(p.inv_nr_vt).minC(80.0);
    const i_rec = arg_rec.exp().addC(-1.0).scale(p.isr);
    id_val = id_val.add(i_rec);

    // --- Sidewall current ---
    const arg_sw = vd.scale(p.inv_ns_vt).minC(80.0);
    const i_sw = arg_sw.exp().addC(-1.0).scale(p.jsw_pj);
    id_val = id_val.add(i_sw);

    // --- Tunneling current ---
    // Tunneling flows in reverse direction (negative vd)
    const arg_tun = vd.scale(-p.inv_ntun_vt).minC(80.0);
    const tun_exp = arg_tun.exp().addC(-1.0);
    const i_tun = tun_exp.scale(p.jtun_area);
    const i_tun_sw = tun_exp.scale(p.jtunsw_pj);
    id_val = id_val.sub(i_tun.add(i_tun_sw));

    // --- High-injection knee current (IKF forward, IKR reverse) ---
    // When ikf/ikr = 0, treat as infinite (no knee effect)
    // IKF applies when id_val > 0 (forward), IKR when id_val < 0 (reverse)
    // (region branch: original code also selected ik on the current sign)
    const ik_eff: f64 = if (id_val.val() >= 0.0)
        (if (p.ikf > 0.0) p.ikf else 1.0e30)
    else
        (if (p.ikr > 0.0) p.ikr else 1.0e30);
    const ik_denom = id_val.abs().scale(1.0 / ik_eff).addC(1.0).maxC(1e-30).sqrt();
    id_val = id_val.div(ik_denom);

    // --- Reverse breakdown current ---
    // Use IBV (not IS) as pre-exponential so I=IBV at Vd=-BV, matching ngspice.
    // Piecewise: only active near breakdown; linearize in deep breakdown to avoid inf.
    if (p.bv > 0.0) {
        const nbv_vt = 1.0 / p.inv_nbv_vt;
        const bd_thresh = -p.bv + 5.0 * nbv_vt;
        if (vd.val() < bd_thresh) {
            const arg_bd = vd.addC(p.bv).scale(-p.inv_nbv_vt).minC(40.0);
            const i_bd = if (arg_bd.val() > 40.0 - 1e-10) blk: {
                // Deep breakdown: linearize at arg=40 to prevent huge currents
                const exp40 = contract.fmath.exp(@as(f64, 40.0));
                const i_at_40 = p.ibv_val * exp40;
                const g_at_40 = i_at_40 * p.inv_nbv_vt;
                const dv = vd.addC(p.bv + 40.0 / p.inv_nbv_vt);
                break :blk dv.scale(-g_at_40).addC(-i_at_40);
            } else blk: {
                break :blk arg_bd.exp().scale(p.ibv_val).neg();
            };
            id_val = id_val.add(i_bd);
        }
    }

    // --- GMIN convergence conductance ---
    id_val = id_val.add(vd.scale(gmin));

    // --- Conductance (COND parameter) ---
    id_val = id_val.add(vd.scale(p.cond));

    // --- Area and multiplier scaling ---
    id_val = id_val.scale(p.area_m);

    // --- Series resistance ---
    const i_rs = x[p_idx].sub(x[pp]).scale(p.g_rs);

    // --- KCL node stamps ---
    var out: [n_u]S = undefined;
    out[p_idx] = i_rs;
    out[n_] = id_val.neg();
    out[pp] = id_val.sub(i_rs);
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

    const p_idx = @intFromEnum(U.p);
    const n_ = @intFromEnum(U.n);
    const pp = @intFromEnum(U.p_prime);

    const p = &pc.q;

    // --- Junction voltage (x-dependent from here on) ---
    const vd = x[pp].sub(x[n_]);

    // ========================================================================
    // Bottom Junction Depletion Charge
    // ========================================================================

    // Region branch on voltage: vd < FC * VJ selects the depletion form,
    // otherwise the quadratic strong-forward extension (as in the original).
    const q_bottom_raw: S = if (vd.val() < p.fc_vj) blk: {
        // Reverse/moderate forward bias region: vd < FC * VJ
        const x_dep = vd.scale(-1.0 / p.vj).addC(1.0).maxC(1e-30);
        const q_dep = x_dep.log().scale(p.one_minus_m).exp().neg().addC(1.0).scale(p.cjo_vj_over_om);
        break :blk q_dep;
    } else blk: {
        // Strong forward bias region: vd >= FC * VJ (quadratic extension)
        const lin_bot = vd.addC(-p.fc_vj).scale(p.f3_bot);
        const quad_bot = vd.mul(vd).addC(-(p.fc_vj * p.fc_vj)).scale(p.m_over_2vj);
        break :blk lin_bot.add(quad_bot).scale(p.cjo_over_f2_bot).addC(p.f1_bot);
    };
    const q_bottom = q_bottom_raw.scale(p.area);

    // ========================================================================
    // Sidewall Depletion Charge
    // ========================================================================

    const q_sw: S = if (vd.val() < p.fcs_php) blk: {
        // Reverse/moderate forward bias region: vd < FCS * PHP
        const x_sw_dep = vd.scale(-1.0 / p.php).addC(1.0).maxC(1e-30);
        break :blk x_sw_dep.log().scale(p.one_minus_mjsw).exp().neg().addC(1.0).scale(p.cjp_pj_php_over_omjsw);
    } else blk: {
        // Strong forward bias region: vd >= FCS * PHP (quadratic extension)
        const lin_sw = vd.addC(-p.fcs_php).scale(p.f3_sw);
        const quad_sw = vd.mul(vd).addC(-(p.fcs_php * p.fcs_php)).scale(p.mjsw_over_2php);
        break :blk lin_sw.add(quad_sw).scale(p.cjp_pj_over_f2_sw).addC(p.f1_sw);
    };

    // ========================================================================
    // Diffusion Charge (Transit Time)
    // ========================================================================
    const arg_diff = vd.scale(p.inv_n_vt).minC(80.0);
    const id_fwd = arg_diff.exp().addC(-1.0).scale(p.is_val);
    const q_diff = id_fwd.scale(p.tt * p.area);

    // ========================================================================
    // Total Charge with Multiplier
    // ========================================================================
    const q_total = q_bottom.add(q_sw).add(q_diff).scale(p.m_mult);

    // --- Charge node stamps ---
    var out: [n_u]S = undefined;
    out[p_idx] = S.con(0.0);
    out[pp] = q_total;
    out[n_] = q_total.neg();
    return out;
}

// ============================================================================
// Voltage Limiting (DEVpnjlim)
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const pp = @intFromEnum(U.p_prime);
    const n_ = @intFromEnum(U.n);

    const is_val: f64 = @as(f64, model.is);
    const n_em: f64 = @as(f64, model.n);
    const tnom: f64 = @as(f64, model.tnom);
    const vt: f64 = 8.617333e-5 * (tnom + 273.15);
    const nvt = n_em * vt;

    // Critical voltage
    const v_crit = nvt * contract.fmath.log(nvt / (@sqrt(2.0) * is_val));

    // Junction voltages
    const vd_new = x_new[pp] - x_new[n_];
    const vd_old = x_old[pp] - x_old[n_];

    var vd_limited = vd_new;

    // --- Reverse breakdown voltage limiting (DEVpnjlim) ---
    const bv: f64 = @as(f64, model.bv);
    const nbv: f64 = @as(f64, model.nbv);
    if (bv > 0.0) {
        const vte = nbv * vt;
        if (vd_limited < @min(0.0, -bv + 10.0 * vte)) {
            if (vd_old > 0.0) {
                // Jumped from forward to deep reverse — clamp to -BV
                vd_limited = -bv;
            } else {
                // Already in reverse — log-compress the step. Only valid
                // for arg > 2 (log(arg - 2) is NaN below that); ngspice's
                // pnjlim on -(vd + bv) takes the plain step below the
                // log-form threshold.
                const arg = -(vd_limited + bv) / vte;
                if (arg > 2.0) {
                    vd_limited = -(bv + vte * (2.0 + contract.fmath.log(arg - 2.0)));
                }
            }
        }
    }

    // --- Forward bias limiting ---
    // Apply limiting when vd_limited > v_crit and step is large
    // ngspice DEVpnjlim: arg = 1 + delta/nvt, vnew = vold + nvt*log(arg).
    // (The SPICE2 2+log(arg-2) form diverges to -inf as delta -> 2nvt+.)
    if (vd_limited > v_crit and @abs(vd_limited - vd_old) > 2.0 * nvt) {
        if (vd_old > 0.0) {
            const arg = 1.0 + (vd_limited - vd_old) / nvt;
            vd_limited = if (arg > 0.0) vd_old + nvt * contract.fmath.log(arg) else v_crit;
        } else {
            vd_limited = nvt * contract.fmath.log(vd_limited / nvt);
        }
    }

    // Apply correction to p' only
    const delta = vd_limited - vd_new;
    var result = x_new;
    result[pp] = x_new[pp] + delta;
    return result;
}

// ============================================================================
// Node Collapse (ngspice DIOsetup: posPrimeNode = posNode when RS = 0)
// ============================================================================

pub fn collapse(model: *const Model, _: *const Instance) [n_u]?u8 {
    var out: [n_u]?u8 = @splat(null);
    if (model.rs == 0) out[@intFromEnum(U.p_prime)] = @intFromEnum(U.p);
    return out;
}

// ============================================================================
// Cold-Start Seeding (SPICE MODEINITJCT)
// ============================================================================
// dioload.c: at MODEINITJCT the diode evaluates at vd = vcrit, not the node
// vector. Node-write equivalent on a zeroed x: p' = vcrit (n stays 0), so
// iteration 1 linearizes on the exponential's shoulder and pnjlim limits
// against vcrit instead of 0.

pub fn seed(model: *const Model, _: *const Instance) [n_u]?f64 {
    const is_val: f64 = @as(f64, model.is);
    const n_em: f64 = @as(f64, model.n);
    const tnom: f64 = @as(f64, model.tnom);
    const vt: f64 = 8.617333e-5 * (tnom + 273.15);
    const nvt = n_em * vt;
    const v_crit = nvt * contract.fmath.log(nvt / (@sqrt(2.0) * is_val));
    var out: [n_u]?f64 = @splat(null);
    out[@intFromEnum(U.p_prime)] = v_crit;
    return out;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================
// Scales IS by adding gmin*(1-lambda) to aid DC operating point convergence.
// At lambda=0 the device is essentially a small conductance; at lambda=1
// it is the real model.

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const gmin_step: f64 = 1.0e-12;
    const is_orig: f64 = @as(f64, model.is);
    // Blend: at lambda=0, IS is boosted; at lambda=1, IS is original
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

test "diode: forward bias 0.6V residual" {
    // Old formula, default model (is=1e-14 stored f32 -> 9.9999998245167e-15,
    // n=1, tnom=27), area=1, pj=0, m_mult=1, rs=0:
    //   vt = 8.617333e-5 * (27 + 273.15) = 0.025864924999499998
    //   arg = 0.6 / vt = 23.197...  (< 80, no clamp)
    //   id  = is*(exp(arg) - 1) + gmin*0.6
    //       = 9.9999998245167e-15 * (exp(23.197...) - 1) + 6e-13
    //       = 0.00011871877648628485
    // x = {p, n, p'} = {0.6, 0.0, 0.6}: i_rs = (0.6-0.6)*1e12 = 0
    //   out[p] = 0, out[n] = -id, out[p'] = id
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 0.6, 0.0, 0.6 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.p)], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -0.00011871877648628485), out[@intFromEnum(U.n)], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.00011871877648628485), out[@intFromEnum(U.p_prime)], 1e-15);
}

test "diode: deep reverse saturation residual" {
    // vd = -1 < -3*n*vt = -0.0776 -> deep reverse branch: id = -is
    // plus gmin conductance: id = -9.9999998245167e-15 + 1e-12*(-1)
    //                          = -1.0099999998245167e-12
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ -1.0, 0.0, -1.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1.0099999998245167e-12), out[@intFromEnum(U.n)], 1e-24);
    try testing.expectApproxEqAbs(@as(f64, -1.0099999998245167e-12), out[@intFromEnum(U.p_prime)], 1e-24);
}

test "diode: depletion charge at vd=-1" {
    // cjo=1e-12, vj=1, m=0.5, fc=0.5; vd=-1 < fc*vj=0.5 -> depletion branch:
    //   x_dep = 1 - (-1)/1 = 2
    //   q_dep = (cjo*vj/(1-m)) * (1 - exp((1-m)*ln(2)))
    //         = 2e-12 * (1 - sqrt(2)) = -8.284271214359584e-13
    const model: Model = .{ .cjo = 1e-12 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ -1.0, 0.0, -1.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.p)], 1e-30);
    try testing.expectApproxEqAbs(@as(f64, -8.284271214359584e-13), out[@intFromEnum(U.p_prime)], 1e-24);
    try testing.expectApproxEqAbs(@as(f64, 8.284271214359584e-13), out[@intFromEnum(U.n)], 1e-24);
}

test "diode: strong-forward charge with diffusion at vd=0.6" {
    // cjo=1e-12, vj=1, m=0.5, fc=0.5, tt=1e-9; vd=0.6 >= fc*vj=0.5 -> quadratic:
    //   f1 = 2e-12*(1 - exp(0.5*ln(0.5))) = 2e-12*(1 - 1/sqrt(2)) = 5.857864352862177e-13
    //   f2 = exp(1.5*ln(0.5)) = 0.3535533905932738
    //   f3 = 1 - 0.5*1.5 = 0.25
    //   q_fwd = f1 + (cjo/f2)*(f3*(0.6-0.5) + (m/(2*vj))*(0.36-0.25))
    //         = f1 + 2.828427e-12*(0.025 + 0.0275) = 7.342788587420462e-13
    //   q_diff = tt*is*(exp(0.6/vt)-1) = 1e-9 * 1.1871877e-4 = 1.1871877252868856e-13
    //   q_total = 8.529976312707348e-13
    const model: Model = .{ .cjo = 1e-12, .tt = 1e-9 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 0.6, 0.0, 0.6 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 8.529976312707348e-13), out[@intFromEnum(U.p_prime)], 1e-24);
    try testing.expectApproxEqAbs(@as(f64, -8.529976312707348e-13), out[@intFromEnum(U.n)], 1e-24);
}

test "diode: series resistance splits voltage stamp" {
    // rs=10, area=1, m_mult=1 -> g_rs = 0.1. x = {1.0, 0.0, 0.6}:
    //   i_rs = (1.0 - 0.6)*0.1 = 0.04
    //   vd = 0.6 -> junction id = 0.00011871877648628485 (same as forward test)
    //   out[p] = 0.04, out[n] = -id, out[p'] = id - 0.04
    const model: Model = .{ .rs = 10 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 0.6 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.04), out[@intFromEnum(U.p)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.00011871877648628485), out[@intFromEnum(U.n)], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.00011871877648628485 - 0.04), out[@intFromEnum(U.p_prime)], 1e-12);
}
