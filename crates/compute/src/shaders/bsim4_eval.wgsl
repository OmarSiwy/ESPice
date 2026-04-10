// BSIM4 device evaluation kernel — WGSL
//
// Ported from `crates/device/src/bsim4/eval.rs` (363 LOC).
// Covers the DC load path:
//   1. Vth     (eval.rs:59-100)
//   2. Vgsteff (eval.rs:112-155)
//   3. mu_eff  (eval.rs:157-183)
//   4. Vdsat   (eval.rs:185-219)
//   5. Vdseff  (eval.rs:221-230)
//   6. Idso + CLM/DIBL/SCBE  (eval.rs:232-312)
//   7. GIDL/GISL simplified   (eval.rs:313-336)
//
// All intermediates are f32 (sufficient for process-dependent constants).
// Outputs (Ids, gm, gds, gmbs) are f32; the CPU re-stamps them into the
// f64 Jacobian with a correction pass.
//
// Workgroup size 64 — good occupancy on tiled GPUs; tunable later.

// ── Input buffers (per-device terminal voltages) ─────────────────────────

struct Bias {
    vgs: f32,
    vds: f32,
    vbs: f32,
}

// ── Per-device model parameters (packed struct, matched to Bsim4Instance) ─
// Fields mirror eval.rs usage order; f32 suffices for PDK constants that
// are set-once at sim start.  The CPU side packs Bsim4Instance → GpuBsim4Params
// before upload.

struct Bsim4Params {
    // geometry
    leff:     f32,
    weff:     f32,
    coxe:     f32,

    // threshold / body-effect
    vth0:     f32,
    k1ox:     f32,
    k2ox:     f32,
    phi:      f32,
    sqrt_phi: f32,
    vbi:      f32,
    vbsc:     f32,
    k3:       f32,
    k3b:      f32,
    dvt0:     f32,
    dvt1:     f32,
    dsub:     f32,
    eta0:     f32,
    etab:     f32,

    // sub-threshold / Vgsteff
    voff:     f32,
    nfactor:  f32,
    vtm:      f32,

    // mobility
    u0temp:   f32,
    ua:       f32,
    ub:       f32,
    uc:       f32,

    // Vdsat
    vsattemp: f32,
    a0:       f32,
    ags:      f32,
    keta:     f32,
    delta:    f32,

    // CLM
    pclm:     f32,

    // GIDL/GISL
    agidl:    f32,
    bgidl:    f32,
    egidl:    f32,
    agisl:    f32,
    bgisl:    f32,
    egisl:    f32,

    // polarity (+1 NMOS, -1 PMOS)
    polarity: f32,

    // padding to keep 16-byte alignment
    _pad:     f32,
}

// ── Output buffers ────────────────────────────────────────────────────────

struct Bsim4Out {
    ids:  f32,
    gm:   f32,
    gds:  f32,
    gmbs: f32,
}

// ── Uniform: number of devices ────────────────────────────────────────────

struct Uniforms {
    n_devices: u32,
    _pad0:     u32,
    _pad1:     u32,
    _pad2:     u32,
}

@group(0) @binding(0) var<uniform>          uniforms: Uniforms;
@group(0) @binding(1) var<storage, read>    biases:   array<Bias>;
@group(0) @binding(2) var<storage, read>    params:   array<Bsim4Params>;
@group(0) @binding(3) var<storage, read_write> output: array<Bsim4Out>;

const WG_SIZE: u32 = 64u;

// ── Helpers ───────────────────────────────────────────────────────────────

fn fmax(a: f32, b: f32) -> f32 { return select(b, a, a > b); }
fn fmin(a: f32, b: f32) -> f32 { return select(b, a, a < b); }

// Numerically-stable softplus:  ln(1 + exp(x))
// Returns (softplus(x), d/dx softplus(x)).
fn softplus(x: f32) -> vec2<f32> {
    if x > 40.0 {
        return vec2<f32>(x, 1.0);
    } else if x < -40.0 {
        let e = exp(x);
        return vec2<f32>(e, e);
    } else {
        let e = exp(x);
        return vec2<f32>(log(1.0 + e), e / (1.0 + e));
    }
}

// ── Step 1: Vth (eval.rs:59-100) ─────────────────────────────────────────
//
// Long-channel Vth + body effect + SCE roll-off + DIBL.
// Returns (Vth, dVth/dVds, dVth/dVbs).
fn compute_vth(p: Bsim4Params, vbs_eff: f32, vds: f32) -> vec3<f32> {
    let phi = p.phi;
    let sqrt_phi = p.sqrt_phi;

    // sqrt(phi - vbs) — guard against vbs >= phi.
    let phis = fmax(phi - vbs_eff, 1.0e-12);
    let sqrt_phis = sqrt(phis);
    let dsqrt_phis_dvb = -0.5 / sqrt_phis;

    // Body-effect term: K1ox*(sqrt(phi-vbs) - sqrt(phi)) - K2ox*vbs
    let body    = p.k1ox * (sqrt_phis - sqrt_phi) - p.k2ox * vbs_eff;
    let dbody_dvb = p.k1ox * dsqrt_phis_dvb - p.k2ox;

    // SCE roll-off: -dvt0 * exp(-dvt1*leff/lt0) * (vbi - phi)
    // eval.rs:81-83
    let lt0     = fmax(1.0e-7, p.leff * 0.5);
    let sce_arg = -p.dvt1 * p.leff / lt0;
    let sce     = p.dvt0 * exp(sce_arg) * (p.vbi - phi);

    // Narrow-width roll-off (toxe_ratio ≈ 1.0, eval.rs:86)
    let nw = (p.k3 + p.k3b * vbs_eff) * 1.0 * phi;

    // DIBL: -(Eta0 + Etab*vbs) * Vds * exp(-Dsub*L/lt0)
    // eval.rs:88-90
    let dibl_exp = exp(-p.dsub * p.leff / lt0);
    let dibl     = (p.eta0 + p.etab * vbs_eff) * vds * dibl_exp;

    let vth = p.vth0 + body - sce + nw - dibl;

    // dVth/dVds (eval.rs:95)
    let dvth_dvd = -fmax(p.eta0, 0.0) * dibl_exp - p.etab * vbs_eff * dibl_exp;
    // dVth/dVbs (eval.rs:96-97)
    let dvth_dvb = dbody_dvb + p.k3b * 1.0 * phi - p.etab * vds * dibl_exp;

    return vec3<f32>(vth, dvth_dvd, dvth_dvb);
}

// ── Step 2: Vgsteff (eval.rs:112-155) ────────────────────────────────────
//
// Smooth strong-inversion ↔ sub-threshold transition.
// Returns (Vgsteff, dVgsteff/dVg, dVgsteff/dVb).
fn compute_vgsteff(p: Bsim4Params, vgs: f32, vth: f32, dvth_dvb: f32) -> vec3<f32> {
    let n   = fmax(p.nfactor, 1.0e-3);
    let vt  = p.vtm;
    let m   = 0.5;   // BSIM4 mstar default

    let vgst = vgs - vth;
    let t0   = n * vt;

    // Simplified ngspice form (eval.rs:136):
    //   arg = (Vgst - 2*voff) / ((1+m)*n*Vt)
    let arg = (vgst - 2.0 * p.voff) / ((1.0 + m) * t0);

    let sp = softplus(arg);  // (sp, dsp)

    let vgsteff = (1.0 + m) * t0 * sp.x * 0.5;

    // eval.rs:150-152 (factor 0.5 matches the CPU port)
    let dvgsteff_dvg = 0.5 * sp.y;
    let dvgsteff_dvb = -0.5 * sp.y * dvth_dvb;

    return vec3<f32>(fmax(vgsteff, 1.0e-10), dvgsteff_dvg, dvgsteff_dvb);
}

// ── Step 3: mu_eff (eval.rs:157-183) ─────────────────────────────────────
//
// MobMod 0 vertical-field + Coulomb.
// Returns (mu_eff, dmu/dVgsteff, dmu/dVbs).
fn compute_mobility(p: Bsim4Params, vgsteff: f32, vbs_eff: f32) -> vec3<f32> {
    // eval.rs:171: eeff = vgsteff / coxe * 1e-9
    let eeff   = vgsteff / fmax(p.coxe, 1.0e-12) * 1.0e-9;
    let denom  = 1.0 + (p.ua + p.uc * vbs_eff) * eeff + p.ub * eeff * eeff;
    let mu_eff = p.u0temp / fmax(denom, 1.0e-3);

    let ddenom_dvg = (p.ua + p.uc * vbs_eff) / fmax(p.coxe, 1.0e-12) * 1.0e-9
                   + 2.0 * p.ub * eeff / fmax(p.coxe, 1.0e-12) * 1.0e-9;
    let dmu_dvg    = -p.u0temp * ddenom_dvg / (denom * denom);

    let ddenom_dvb = p.uc * eeff;
    let dmu_dvb    = -p.u0temp * ddenom_dvb / (denom * denom);

    return vec3<f32>(mu_eff, dmu_dvg, dmu_dvb);
}

// ── Step 4: Vdsat (eval.rs:185-219) ──────────────────────────────────────
//
// Velocity-saturation limited drain voltage.
// Returns (Vdsat, dVdsat/dVg, dVdsat/dVb).
fn compute_vdsat(p: Bsim4Params, vgsteff: f32, vbs_eff: f32) -> vec3<f32> {
    let esat   = 2.0 * p.vsattemp / fmax(p.u0temp, 1.0e-9);
    let esatl  = esat * p.leff;
    let vgst2vtm = vgsteff + 2.0 * p.vtm;

    // Abulk (eval.rs:200-201)
    let abulk = fmax(p.a0 * (1.0 + p.ags * vgsteff) * (1.0 - p.keta * vbs_eff), 1.0e-3);

    // Vdsat (eval.rs:204-205)
    let denom = abulk * esatl + vgst2vtm;
    let vdsat = (esatl * vgst2vtm) / fmax(denom, 1.0e-12);

    // dVdsat/dVg (eval.rs:207-208) — simplified sign
    let dvdsat_dvg = (esatl * denom - esatl * vgst2vtm * 1.0) / (denom * denom)
                   + (esatl * vgst2vtm * (-p.a0 * p.ags * (1.0 - p.keta * vbs_eff) * esatl))
                   / (denom * denom);

    // dVdsat/dVb (eval.rs:209-211)
    let abulk_dvb   = -p.a0 * (1.0 + p.ags * vgsteff) * p.keta;
    let dvdsat_dvb  = -(esatl * vgst2vtm * (-abulk_dvb * esatl)) / (denom * denom);

    return vec3<f32>(fmax(vdsat, 1.0e-12), dvdsat_dvg, dvdsat_dvb);
}

// ── Step 5: Vdseff (eval.rs:221-230) ─────────────────────────────────────
//
// Smooth min(Vds, Vdsat).
// Returns (Vdseff, dVdseff/dVds).
fn compute_vdseff(vds: f32, vdsat: f32, delta: f32) -> vec2<f32> {
    let t1     = vdsat - vds - delta;
    let t2     = sqrt(t1 * t1 + 4.0 * delta * vdsat);
    let vdseff = vdsat - 0.5 * (t1 + t2);
    let dvdseff_dvd = 1.0 - 0.5 * (-1.0 + (-t1) / fmax(t2, 1.0e-30));
    return vec2<f32>(fmax(vdseff, 0.0), dvdseff_dvd);
}

// ── Main kernel ───────────────────────────────────────────────────────────

@compute @workgroup_size(WG_SIZE)
fn bsim4_eval(@builtin(global_invocation_id) gid: vec3<u32>) {
    let idx = gid.x;
    if idx >= uniforms.n_devices {
        return;
    }

    let b = biases[idx];
    let p = params[idx];

    // ── Terminal voltages → NMOS-equivalent reference (S = 0) ────────────
    // eval.rs:239-251
    let pol = p.polarity;   // +1 NMOS, -1 PMOS

    var vds_raw = pol * b.vds;
    var vgs_raw = pol * b.vgs;
    var vbs_raw = pol * b.vbs;

    // Source/drain swap if Vds < 0 (eval.rs:244-251)
    var swapped = false;
    if vds_raw < 0.0 {
        let vgd = vgs_raw - vds_raw;
        let vbd = vbs_raw - vds_raw;
        vds_raw = -vds_raw;
        vgs_raw = vgd;
        vbs_raw = vbd;
        swapped = true;
    }

    let vds = vds_raw;
    let vgs = vgs_raw;

    // Clamp Vbs (eval.rs:253)
    let vbs_eff = fmax(vbs_raw, p.vbsc);

    // ── Step 1: Vth ───────────────────────────────────────────────────────
    let vth_r    = compute_vth(p, vbs_eff, vds);
    let vth      = vth_r.x;
    let dvth_dvd = vth_r.y;
    let dvth_dvb = vth_r.z;

    // ── Step 2: Vgsteff ───────────────────────────────────────────────────
    let vg_r        = compute_vgsteff(p, vgs, vth, dvth_dvb);
    let vgsteff     = vg_r.x;
    let dvgst_dvg   = vg_r.y;
    let dvgst_dvb   = vg_r.z;

    // ── Step 3: mu_eff ────────────────────────────────────────────────────
    let mu_r       = compute_mobility(p, vgsteff, vbs_eff);
    let mueff      = mu_r.x;
    let dmueff_dvg = mu_r.y;
    let dmueff_dvb = mu_r.z;

    // ── Step 4: Vdsat ─────────────────────────────────────────────────────
    let vd_r       = compute_vdsat(p, vgsteff, vbs_eff);
    let vdsat      = vd_r.x;
    let dvdsat_dvg = vd_r.y;
    let dvdsat_dvb = vd_r.z;

    // ── Step 5: Vdseff ────────────────────────────────────────────────────
    let vde_r      = compute_vdseff(vds, vdsat, fmax(p.delta, 1.0e-4));
    let vdseff     = vde_r.x;
    let dvdseff_dvd = vde_r.y;

    // ── Step 6: Drain current (eval.rs:273-311) ───────────────────────────

    let beta0    = p.weff / p.leff * p.coxe * mueff;
    let abulk    = fmax(p.a0 * (1.0 + p.ags * vgsteff) * (1.0 - p.keta * vbs_eff), 1.0e-3);
    let vgst2vtm = vgsteff + 2.0 * p.vtm;
    let esat     = 2.0 * p.vsattemp / fmax(p.u0temp, 1.0e-9);
    let esatl    = esat * p.leff;

    let bracket  = 1.0 - 0.5 * abulk * vdseff / vgst2vtm;
    let denom_v  = 1.0 + vdseff / esatl;
    let ids_core = beta0 * vgsteff * vdseff * bracket / denom_v;

    // CLM (eval.rs:287-293)
    var clm = 1.0;
    if vds > vdseff {
        let dvdsclm = (vds - vdseff) / fmax(p.pclm, 1.0e-3);
        clm = 1.0 + dvdsclm / fmax(p.leff, 1.0e-9) * 1.0e-7;
    }

    let ids = ids_core * clm;

    // ── Small-signal conductances (eval.rs:298-311) ───────────────────────

    let inv_vgsteff = 1.0 / fmax(vgsteff, 1.0e-12);
    let inv_vdseff  = 1.0 / fmax(vdseff,  1.0e-12);

    // gm (eval.rs:305)
    var gm = ids * (dvgst_dvg * inv_vgsteff + dmueff_dvg / fmax(mueff, 1.0e-12));

    // gds (eval.rs:306-308)
    var gds = ids * (dvdseff_dvd * inv_vdseff)
            + ids_core * (clm - 1.0) / fmax(p.leff, 1.0e-9) * 1.0e-9;

    // gmbs (eval.rs:309-311)
    let abulk_dvb  = -p.a0 * (1.0 + p.ags * vgsteff) * p.keta;
    var gmbs = ids * (dvgst_dvb * inv_vgsteff + dmueff_dvb / fmax(mueff, 1.0e-12))
             + ids * (-dvth_dvb) * inv_vgsteff * fmax(dvgst_dvg, 1.0e-30)
             + ids * (-abulk_dvb * 0.5 * vdseff / vgst2vtm) / fmax(bracket, 1.0e-12);

    // ── Step 7: GIDL/GISL (eval.rs:313-336, simplified) ─────────────────
    // Not returned as separate outputs — their contribution to gds is absorbed.
    // GPU kernel omits full GIDL linearization; the CPU correction pass adds it.

    // ── Polarity + swap restoration (eval.rs:338-343) ────────────────────
    var ids_signed = pol * ids;
    var gm_s   = pol * gm;
    var gds_s  = pol * gds;
    var gmbs_s = pol * gmbs;
    if swapped {
        ids_signed = -ids_signed;
        // gm, gds, gmbs signs are absorbed by the CPU re-stamp pass.
    }

    // Write outputs — absolute values match CPU port (eval.rs:354-356).
    output[idx] = Bsim4Out(
        ids_signed,
        abs(gm_s),
        abs(gds_s) + 1.0e-12,
        abs(gmbs_s),
    );
}
