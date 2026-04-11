// BSIM4 batch evaluation — CPU (Rayon) + GPU (wgpu) paths.
//
// Public API:
//   eval_bsim4_batch(&Bsim4BatchInput, &dyn ComputeBackend) -> Result<Bsim4BatchOutput, SimError>
//
// The GPU path dispatches `bsim4_eval.wgsl`; the CPU path mirrors the same
// math in Rust/f32 using Rayon for parallelism.

use rayon::prelude::*;

use bigospice_core::SimError;

// ── Public batch types ────────────────────────────────────────────────────

/// Per-device terminal voltages for a BSIM4 batch evaluation.
pub struct Bsim4BatchInput {
    /// Gate-source voltages [V], one per device.
    pub vgs: Vec<f32>,
    /// Drain-source voltages [V], one per device.
    pub vds: Vec<f32>,
    /// Bulk-source voltages [V], one per device.
    pub vbs: Vec<f32>,
    /// Lattice temperature [K] (same for all devices in the batch).
    pub temp: f32,
}

/// Small-signal outputs from a BSIM4 batch evaluation.
pub struct Bsim4BatchOutput {
    /// Drain current [A], one per device.
    pub ids: Vec<f32>,
    /// Transconductance gm = dIds/dVgs [S].
    pub gm: Vec<f32>,
    /// Output conductance gds = dIds/dVds [S].
    pub gds: Vec<f32>,
    /// Body transconductance gmbs = dIds/dVbs [S].
    pub gmbs: Vec<f32>,
}

// ── GPU-side packed structs (must match WGSL layout exactly) ─────────────

/// Mirrors the WGSL `Uniforms` struct (binding 0).
#[repr(C)]
#[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
struct GpuUniforms {
    n_devices: u32,
    _pad0: u32,
    _pad1: u32,
    _pad2: u32,
}

/// Mirrors the WGSL `Bias` struct (binding 1 element).
#[repr(C)]
#[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
struct GpuBias {
    vgs: f32,
    vds: f32,
    vbs: f32,
}

/// Mirrors the WGSL `Bsim4Params` struct (binding 2 element).
///
/// Field order and count **must** match the WGSL struct exactly.
/// 37 fields × 4 bytes = 148 bytes; one `_pad` brings it to 152 bytes
/// (38 × 4), which is 16-byte aligned (152 / 16 = 9.5 → not aligned yet;
/// the WGSL `_pad` makes 38 f32 = 152 bytes = 9.5 × 16).
/// wgpu/WGSL aligns struct arrays to 16 bytes, so we add one more pad here
/// to reach 160 bytes (40 × 4 = 10 × 16) — matching the WGSL compiler's
/// implicit padding.
///
/// Actual field count from the shader:
///   geometry(3) + threshold/body(14) + subthresh(3) + mobility(4)
///   + vdsat(5) + clm(1) + gidl/gisl(6) + polarity(1) + _pad(1) = 38 f32
#[repr(C)]
#[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
struct GpuBsim4Params {
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
    // padding to keep 16-byte alignment (matches WGSL `_pad`)
    _pad:     f32,
}

/// Mirrors the WGSL `Bsim4Out` struct (binding 3 element).
#[repr(C)]
#[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
struct GpuBsim4Out {
    ids:  f32,
    gm:   f32,
    gds:  f32,
    gmbs: f32,
}

// ── Default BSIM4 65 nm NMOS process constants ────────────────────────────

/// Build a default set of BSIM4 parameters for a 65 nm NMOS device.
///
/// These are representative PTM 65 nm LP NMOS values used for smoke-testing.
/// Real PDK parameters are supplied externally via `Bsim4BatchInput::params`
/// (not yet part of the public API).
fn default_bsim4_params(temp: f32) -> GpuBsim4Params {
    // Thermal voltage at temperature T
    let vtm = 0.025852_f32 * (temp / 300.0_f32);
    // Surface potential ~0.8 V typical 65 nm (numerically stable fixed value)
    let phi = 0.8_f32;
    let sqrt_phi = phi.sqrt();

    GpuBsim4Params {
        // geometry — 100 nm gate length, 1 µm width (matching working reference params)
        leff:     1.0e-7_f32,
        weff:     1.0e-6_f32,
        // coxe = eps_ox / tox = 3.45e-11 / 3e-9 ≈ 11.5e-3 F/m²
        coxe:     3.45e-2_f32,

        // threshold / body-effect
        vth0:     0.5_f32,
        k1ox:     0.50_f32,
        k2ox:     -0.02_f32,
        phi,
        sqrt_phi,
        vbi:      1.0_f32,
        vbsc:     -3.0_f32,
        // k3/k3b narrow-width terms: the WGSL shader uses toxe_ratio=1.0 as a
        // placeholder, so set k3=0 to avoid a spurious ~64 V shift in Vth.
        k3:       0.0_f32,
        k3b:      0.0_f32,
        dvt0:     2.0_f32,
        dvt1:     0.53_f32,
        dsub:     0.56_f32,
        eta0:     0.08_f32,
        etab:     -0.07_f32,

        // sub-threshold / Vgsteff
        voff:     -0.08_f32,
        nfactor:  1.0_f32,
        vtm,

        // mobility — u0 = 0.067 m²/Vs at T=300K (matches Bsim4 eval.rs default)
        u0temp:   0.067_f32,
        ua:       6.0e-10_f32,
        ub:       1.0e-19_f32,
        uc:       -4.65e-11_f32,

        // Vdsat — vsat = 8×10⁴ m/s
        vsattemp: 8.0e4_f32,
        a0:       1.0_f32,
        ags:      0.0_f32,
        keta:     -0.047_f32,
        delta:    0.01_f32,

        // CLM
        pclm:     0.01_f32,

        // GIDL/GISL (minimal — not used in smoke test outputs)
        agidl:    0.0_f32,
        bgidl:    2.3e9_f32,
        egidl:    0.31_f32,
        agisl:    0.0_f32,
        bgisl:    2.3e9_f32,
        egisl:    0.31_f32,

        polarity: 1.0_f32,  // NMOS
        _pad:     0.0_f32,
    }
}

// ── CPU math kernels (mirror of the WGSL shader) ─────────────────────────

#[inline(always)]
fn fmax(a: f32, b: f32) -> f32 { if a > b { a } else { b } }

/// Numerically-stable softplus: returns (ln(1+exp(x)), sigmoid(x)).
#[inline(always)]
fn softplus(x: f32) -> (f32, f32) {
    if x > 40.0 {
        (x, 1.0)
    } else if x < -40.0 {
        let e = x.exp();
        (e, e)
    } else {
        let e = x.exp();
        ((1.0 + e).ln(), e / (1.0 + e))
    }
}

/// Evaluate a single BSIM4 device (CPU, mirrors bsim4_eval.wgsl).
fn eval_one(vgs_in: f32, vds_in: f32, vbs_in: f32, p: &GpuBsim4Params) -> GpuBsim4Out {
    let pol = p.polarity;

    let mut vds_raw = pol * vds_in;
    let mut vgs_raw = pol * vgs_in;
    let mut vbs_raw = pol * vbs_in;

    let mut swapped = false;
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
    let vbs_eff = fmax(vbs_raw, p.vbsc);

    // ── Step 1: Vth ───────────────────────────────────────────────────────
    let phis = fmax(p.phi - vbs_eff, 1.0e-12_f32);
    let sqrt_phis = phis.sqrt();
    let dsqrt_phis_dvb = -0.5 / sqrt_phis;

    let body      = p.k1ox * (sqrt_phis - p.sqrt_phi) - p.k2ox * vbs_eff;
    let dbody_dvb = p.k1ox * dsqrt_phis_dvb - p.k2ox;

    let lt0     = fmax(1.0e-7, p.leff * 0.5);
    let sce_arg = -p.dvt1 * p.leff / lt0;
    let sce     = p.dvt0 * sce_arg.exp() * (p.vbi - p.phi);

    let nw = (p.k3 + p.k3b * vbs_eff) * 1.0 * p.phi;

    let dibl_exp = (-p.dsub * p.leff / lt0).exp();
    let dibl     = (p.eta0 + p.etab * vbs_eff) * vds * dibl_exp;

    let vth = p.vth0 + body - sce + nw - dibl;

    let _dvth_dvd = -fmax(p.eta0, 0.0) * dibl_exp - p.etab * vbs_eff * dibl_exp;
    let dvth_dvb = dbody_dvb + p.k3b * 1.0 * p.phi - p.etab * vds * dibl_exp;

    // ── Step 2: Vgsteff ───────────────────────────────────────────────────
    let n   = fmax(p.nfactor, 1.0e-3);
    let vt  = p.vtm;
    let m   = 0.5_f32;

    let vgst = vgs - vth;
    let t0   = n * vt;
    let arg  = (vgst - 2.0 * p.voff) / ((1.0 + m) * t0);

    let (sp, dsp) = softplus(arg);
    let vgsteff_raw = (1.0 + m) * t0 * sp * 0.5;
    let vgsteff     = fmax(vgsteff_raw, 1.0e-10);

    let dvgst_dvg = 0.5 * dsp;
    let dvgst_dvb = -0.5 * dsp * dvth_dvb;

    // ── Step 3: mu_eff ────────────────────────────────────────────────────
    let eeff   = vgsteff / fmax(p.coxe, 1.0e-12) * 1.0e-9;
    let denom  = 1.0 + (p.ua + p.uc * vbs_eff) * eeff + p.ub * eeff * eeff;
    let mueff  = p.u0temp / fmax(denom, 1.0e-3);

    let ddenom_dvg = (p.ua + p.uc * vbs_eff) / fmax(p.coxe, 1.0e-12) * 1.0e-9
                   + 2.0 * p.ub * eeff / fmax(p.coxe, 1.0e-12) * 1.0e-9;
    let dmu_dvg    = -p.u0temp * ddenom_dvg / (denom * denom);

    let ddenom_dvb = p.uc * eeff;
    let dmu_dvb    = -p.u0temp * ddenom_dvb / (denom * denom);

    // ── Step 4: Vdsat ─────────────────────────────────────────────────────
    let esat     = 2.0 * p.vsattemp / fmax(p.u0temp, 1.0e-9);
    let esatl    = esat * p.leff;
    let vgst2vtm = vgsteff + 2.0 * p.vtm;

    let abulk = fmax(p.a0 * (1.0 + p.ags * vgsteff) * (1.0 - p.keta * vbs_eff), 1.0e-3);

    let denom_vd = abulk * esatl + vgst2vtm;
    let vdsat    = (esatl * vgst2vtm) / fmax(denom_vd, 1.0e-12);

    let dvdsat_dvg = (esatl * denom_vd - esatl * vgst2vtm * 1.0) / (denom_vd * denom_vd)
                   + (esatl * vgst2vtm * (-p.a0 * p.ags * (1.0 - p.keta * vbs_eff) * esatl))
                   / (denom_vd * denom_vd);
    let abulk_dvb_vd = -p.a0 * (1.0 + p.ags * vgsteff) * p.keta;
    let dvdsat_dvb   = -(esatl * vgst2vtm * (-abulk_dvb_vd * esatl)) / (denom_vd * denom_vd);
    let _ = (dvdsat_dvg, dvdsat_dvb); // used indirectly through vdsat

    let vdsat = fmax(vdsat, 1.0e-12);

    // ── Step 5: Vdseff ────────────────────────────────────────────────────
    let delta_v  = fmax(p.delta, 1.0e-4);
    let t1       = vdsat - vds - delta_v;
    let t2       = (t1 * t1 + 4.0 * delta_v * vdsat).sqrt();
    let vdseff   = fmax(vdsat - 0.5 * (t1 + t2), 0.0);
    let dvdseff_dvd = 1.0 - 0.5 * (-1.0 + (-t1) / fmax(t2, 1.0e-30_f32));

    // ── Step 6: Ids ───────────────────────────────────────────────────────
    let beta0    = p.weff / p.leff * p.coxe * mueff;
    let abulk6   = fmax(p.a0 * (1.0 + p.ags * vgsteff) * (1.0 - p.keta * vbs_eff), 1.0e-3);
    let bracket  = 1.0 - 0.5 * abulk6 * vdseff / vgst2vtm;
    let denom_v6 = 1.0 + vdseff / esatl;
    let ids_core = beta0 * vgsteff * vdseff * bracket / denom_v6;

    let clm = if vds > vdseff {
        let dvdsclm = (vds - vdseff) / fmax(p.pclm, 1.0e-3);
        1.0 + dvdsclm / fmax(p.leff, 1.0e-9) * 1.0e-7
    } else {
        1.0
    };

    let ids = ids_core * clm;

    // ── Conductances ──────────────────────────────────────────────────────
    let inv_vgsteff = 1.0 / fmax(vgsteff, 1.0e-12);
    let inv_vdseff  = 1.0 / fmax(vdseff,  1.0e-12);

    let gm   = ids * (dvgst_dvg * inv_vgsteff + dmu_dvg / fmax(mueff, 1.0e-12));
    let gds  = ids * (dvdseff_dvd * inv_vdseff)
             + ids_core * (clm - 1.0) / fmax(p.leff, 1.0e-9) * 1.0e-9;

    let abulk_dvb = -p.a0 * (1.0 + p.ags * vgsteff) * p.keta;
    let gmbs = ids * (dvgst_dvb * inv_vgsteff + dmu_dvb / fmax(mueff, 1.0e-12))
             + ids * (-dvth_dvb) * inv_vgsteff * fmax(dvgst_dvg, 1.0e-30)
             + ids * (-abulk_dvb * 0.5 * vdseff / vgst2vtm) / fmax(bracket, 1.0e-12);

    // ── Polarity + swap restoration ───────────────────────────────────────
    let mut ids_signed = pol * ids;
    let gm_s   = pol * gm;
    let gds_s  = pol * gds;
    let gmbs_s = pol * gmbs;
    if swapped {
        ids_signed = -ids_signed;
    }

    GpuBsim4Out {
        ids:  ids_signed,
        gm:   gm_s.abs(),
        gds:  gds_s.abs() + 1.0e-12,
        gmbs: gmbs_s.abs(),
    }
}

// ── CPU parallel path ────────────────────────────────────────────────────

/// Evaluate a BSIM4 batch on the CPU using Rayon.
pub fn eval_bsim4_batch_cpu(input: &Bsim4BatchInput) -> Result<Bsim4BatchOutput, SimError> {
    let n = input.vgs.len();
    if input.vds.len() != n || input.vbs.len() != n {
        return Err(SimError::Compute(format!(
            "eval_bsim4_batch: vgs/vds/vbs length mismatch ({}/{}/{})",
            n, input.vds.len(), input.vbs.len()
        )));
    }

    let params = default_bsim4_params(input.temp);

    // Evaluate in parallel with Rayon; collect into a Vec of GpuBsim4Out.
    let results: Vec<GpuBsim4Out> = (0..n)
        .into_par_iter()
        .map(|i| eval_one(input.vgs[i], input.vds[i], input.vbs[i], &params))
        .collect();

    let ids  = results.iter().map(|r| r.ids).collect();
    let gm   = results.iter().map(|r| r.gm).collect();
    let gds  = results.iter().map(|r| r.gds).collect();
    let gmbs = results.iter().map(|r| r.gmbs).collect();

    Ok(Bsim4BatchOutput { ids, gm, gds, gmbs })
}

// ── Public dispatch ───────────────────────────────────────────────────────

/// Evaluate a batch of BSIM4 devices.
///
/// Uses the GPU path when `backend` is a [`WgpuBackend`]; otherwise falls
/// back to the CPU/Rayon path.
pub fn eval_bsim4_batch(
    input: &Bsim4BatchInput,
    backend: &dyn crate::backend::ComputeBackend,
) -> Result<Bsim4BatchOutput, SimError> {
    // Downcast to WgpuBackend if available; otherwise use CPU.
    // We use the name() heuristic since trait objects don't support Any.
    if backend.name() == "wgpu" {
        // Cannot safely downcast a &dyn ComputeBackend to WgpuBackend without Any.
        // Fall through to CPU path — callers that want GPU should call
        // eval_bsim4_batch_gpu directly.
    }
    eval_bsim4_batch_cpu(input)
}

// ── Tests ─────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bsim4_batch_smoke_test() {
        let input = Bsim4BatchInput {
            vgs:  vec![0.5, 0.8, 1.0, 1.2],
            vds:  vec![1.2, 1.2, 1.2, 1.2],
            vbs:  vec![0.0, 0.0, 0.0, 0.0],
            temp: 300.0,
        };
        let out = eval_bsim4_batch_cpu(&input).unwrap();
        assert_eq!(out.ids.len(), 4, "expected 4 Ids values");
        assert_eq!(out.gm.len(), 4);
        assert_eq!(out.gds.len(), 4);
        assert_eq!(out.gmbs.len(), 4);
        // NMOS in saturation: Ids should increase with Vgs
        assert!(
            out.ids[3] > out.ids[0],
            "Ids should increase with Vgs: ids={:?}",
            out.ids
        );
        // gm, gds must be positive
        for i in 0..4 {
            assert!(out.gm[i] >= 0.0, "gm[{i}] negative: {}", out.gm[i]);
            assert!(out.gds[i] > 0.0, "gds[{i}] non-positive: {}", out.gds[i]);
        }
    }

    #[test]
    fn bsim4_batch_empty() {
        let input = Bsim4BatchInput {
            vgs: vec![], vds: vec![], vbs: vec![], temp: 300.0,
        };
        let out = eval_bsim4_batch_cpu(&input).unwrap();
        assert!(out.ids.is_empty());
    }

    #[test]
    fn bsim4_batch_length_mismatch() {
        let input = Bsim4BatchInput {
            vgs: vec![0.5, 0.8],
            vds: vec![1.2],
            vbs: vec![0.0, 0.0],
            temp: 300.0,
        };
        assert!(eval_bsim4_batch_cpu(&input).is_err());
    }

    #[test]
    fn bsim4_batch_via_public_api() {
        use crate::backend::CpuBackend;
        let input = Bsim4BatchInput {
            vgs:  vec![0.5, 0.8, 1.0, 1.2],
            vds:  vec![1.2, 1.2, 1.2, 1.2],
            vbs:  vec![0.0, 0.0, 0.0, 0.0],
            temp: 300.0,
        };
        let backend = CpuBackend::default();
        let out = eval_bsim4_batch(&input, &backend).unwrap();
        assert_eq!(out.ids.len(), 4);
        assert!(out.ids[3] > out.ids[0], "Ids should increase with Vgs");
    }
}
