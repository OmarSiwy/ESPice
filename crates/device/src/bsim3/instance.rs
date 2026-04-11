// BSIM3 — ported from Berkeley BSIM3v3.3 (ECL-2.0)
//
// Per-instance "warm tier": all parameters that need geometry binning
// and temperature pre-compute, baked into a flat `Copy`-able struct.
// This is the analogue of Berkeley's `BSIM3SizeDependParam` after
// `BSIM3temp()` has populated it for one (W,L) pair.
//
// Reference (READ-ONLY):
//   tests/external/ngspice/src/spicelib/devices/bsim3/b3temp.c
//   tests/external/ngspice/src/spicelib/devices/bsim3/b3set.c
//   tests/external/ngspice/src/spicelib/devices/bsim3/bsim3def.h

#![allow(non_snake_case, dead_code)]

use bigospice_core::ParamMap;

use super::model::Bsim3Model;
use super::params::Bsim3Type;

/// Physical constants used by the BSIM3 temperature pre-compute.
pub mod consts {
    pub const Q:        f64 = 1.6021918e-19; // C   — Berkeley value
    pub const KB:       f64 = 1.3806226e-23; // J/K — Berkeley value
    pub const EPS0:     f64 = 8.8542148e-12; // F/m
    pub const EPSSI:    f64 = 1.03594e-10;   // 11.7 * eps0
    pub const EPSOX:    f64 = 3.453143e-11;  // 3.9 * eps0
    pub const NI300:    f64 = 1.45e10 * 1e6; // intrinsic carrier conc /m^3
}

/// Resolved per-instance BSIM3 parameters.  Built once at instance setup
/// time (or on-demand from the model card).  All hot-path code reads
/// from this struct only — never the original model card.
#[derive(Debug, Clone, Copy)]
pub struct Bsim3SizeParams {
    // ── identity ─────────────────────────────────────────────────────────
    pub mos_type:    Bsim3Type,
    pub temp:        f64,        // operating temperature (K)

    // ── geometry ─────────────────────────────────────────────────────────
    pub l_drawn:     f64,        // user W,L (m)
    pub w_drawn:     f64,
    pub leff:        f64,        // electrical L after dl correction
    pub weff:        f64,        // electrical W after dw correction
    pub leffCV:      f64,        // CV-equivalent length
    pub weffCV:      f64,
    pub nf:          f64,        // number of fingers (multiplicity)

    // ── derived oxide / capacitance ─────────────────────────────────────
    pub cox:         f64,        // gate oxide cap per area (F/m^2)
    pub vt_t:        f64,        // kT/q at operating temperature (V)
    pub phi:         f64,        // 2*phi_F at temperature
    pub sqrtPhi:     f64,
    pub Xdep0:       f64,
    pub litl:        f64,        // sqrt(3*xj*tox)
    pub vbi:         f64,
    pub k1ox:        f64,
    pub k2ox:        f64,

    // ── threshold voltage block ─────────────────────────────────────────
    pub vth0:        f64,
    pub k1:          f64,
    pub k2:          f64,
    pub k3:          f64,
    pub k3b:         f64,
    pub w0:          f64,
    pub nlx:         f64,
    pub dvt0:        f64,
    pub dvt1:        f64,
    pub dvt2:        f64,
    pub dvt0w:       f64,
    pub dvt1w:       f64,
    pub dvt2w:       f64,
    pub theta0vb0:   f64,        // pre-computed for SCE term
    pub thetaRout:   f64,        // pre-computed for DIBL term

    pub eta0:        f64,
    pub etab:        f64,
    pub voff:        f64,
    pub nfactor:     f64,
    pub cdsc:        f64,
    pub cdscb:       f64,
    pub cdscd:       f64,
    pub cit:         f64,

    // ── mobility / Vsat ─────────────────────────────────────────────────
    pub mobMod:      i32,
    pub u0temp:      f64,        // u0 * (T/Tnom)^Ute
    pub ua:          f64,
    pub ub:          f64,
    pub uc:          f64,
    pub vsattemp:    f64,        // vsat - at*(T/Tnom-1)
    pub a0:          f64,
    pub ags:         f64,
    pub b0:          f64,
    pub b1:          f64,
    pub keta:        f64,
    pub a1:          f64,
    pub a2:          f64,
    pub rds0:        f64,        // rdsw / weff^wr (per-instance Rds)
    pub prwg:        f64,
    pub prwb:        f64,

    // ── output / CLM / SCBE / DIBL2 ──────────────────────────────────────
    pub pclm:        f64,
    pub pdiblc1:     f64,
    pub pdiblc2:     f64,
    pub pdiblcb:     f64,
    pub drout:       f64,
    pub dsub:        f64,
    pub pscbe1:      f64,
    pub pscbe2:      f64,
    pub pvag:        f64,
    pub delta:       f64,

    // ── substrate impact ionization ──────────────────────────────────────
    pub alpha0:      f64,
    pub alpha1:      f64,
    pub beta0:       f64,

    // ── flat needed by Va decomposition ──────────────────────────────────
    pub vbm:         f64,
    pub xj:           f64,
    pub tox:          f64,
}

impl Bsim3SizeParams {
    /// Resolve a per-instance parameter set from the model card and the
    /// instance's `ParamMap` (which carries W, L, AS, AD, etc.).
    ///
    /// This is a flattened in-place version of Berkeley's `BSIM3temp()`
    /// followed by the `BSIM3SizeDependParam` build loop.
    pub fn resolve(model: &Bsim3Model, inst: &ParamMap) -> Self {
        let p = &model.params;

        // ── 1. Geometry binning ─────────────────────────────────────────
        // L_eff = L_drawn + XL - 2*(LINT + LL/L^lln + LW/W^lwn + LWL/L^lln/W^lwn)
        // W_eff = W_drawn + XW - 2*(WINT + WL/L^wln + WW/W^wwn + WWL/L^wln/W^wwn)
        // (Berkeley `b3temp.c`, lines 130-200.)
        let l_drawn = inst.get_or("l", 1.0e-6);
        let w_drawn = inst.get_or("w", 1.0e-6);
        let nf      = inst.get_or("m", 1.0).max(1.0);

        let l_pow = if p.lln != 0.0 { l_drawn.powf(p.lln) } else { 1.0 };
        let w_pow = if p.lwn != 0.0 { w_drawn.powf(p.lwn) } else { 1.0 };
        let dl = p.lint
            + p.ll  / l_pow
            + p.lw  / w_pow
            + p.lwl / (l_pow * w_pow);

        let l_pow_w = if p.wln != 0.0 { l_drawn.powf(p.wln) } else { 1.0 };
        let w_pow_w = if p.wwn != 0.0 { w_drawn.powf(p.wwn) } else { 1.0 };
        let dw = p.wint
            + p.wl  / l_pow_w
            + p.ww  / w_pow_w
            + p.wwl / (l_pow_w * w_pow_w);

        let leff   = (l_drawn + p.xl - 2.0 * dl).max(1e-9);
        let weff   = (w_drawn + p.xw - 2.0 * dw).max(1e-9);
        let leffCV = leff;  // simplified; full b3 also uses dlc / dwc
        let weffCV = weff;

        // ── 2. Temperature scaling ──────────────────────────────────────
        let temp = inst.get_or("temp", p.tnom);
        let vt_t = consts::KB * temp / consts::Q;
        let tnom = p.tnom;
        let trat = temp / tnom;
        let trat_m1 = trat - 1.0;

        // u0 -> u0temp via u0 * (T/Tnom)^Ute
        let u0temp = p.u0 * trat.powf(p.ute);
        // vsat -> vsat - at*(T/Tnom - 1)
        let vsattemp = (p.vsat - p.at * trat_m1).max(1e3);
        // ua/ub -> ua + ua1*(T/Tnom-1), etc.
        let ua = p.ua + p.ua1 * trat_m1;
        let ub = p.ub + p.ub1 * trat_m1;
        let uc = match p.flags.mobMod {
            // mobMod==3 uses uc absolutely; otherwise it's bias-correction.
            _ => p.uc + p.uc1 * trat_m1,
        };

        // ── 3. Surface potential / Xdep0 / vbi ──────────────────────────
        // ni(T) — from Berkeley constant model.
        let ni = consts::NI300
            * (temp / 300.15).powf(1.5)
            * (-p.npeak.max(1.0).ln() * 0.0  // placeholder term, see eg below
                + (1.5 * (1.0 - 300.15/temp))).exp();
        // The above ni model is a simplification; we use the closed-form
        // ni for Si below for accuracy.
        let eg = 1.16 - 7.02e-4 * temp * temp / (temp + 1108.0);
        let ni_si = 1.45e10
            * (temp / 300.15).powf(1.5)
            * (21.5565981 - eg / (2.0 * vt_t)).exp();
        let _ = ni; // unused, kept for future tnoiMod
        let ni_use = ni_si.max(1e6);

        let phi_user = p.phi;
        let phi = if phi_user > 0.0 {
            phi_user
        } else {
            (2.0 * vt_t * (p.npeak * 1.0e6 / ni_use).ln()).max(0.4)
        };
        let sqrtPhi = phi.sqrt();

        // Xdep0 = sqrt(2*epsSi*phi/(q*npeak)).  npeak is in cm^-3 → m^-3.
        let npeak_m3 = p.npeak * 1.0e6;
        let Xdep0 = (2.0 * consts::EPSSI * phi / (consts::Q * npeak_m3)).sqrt();
        let litl = (3.0 * p.xj * p.tox).sqrt();
        let cox  = consts::EPSOX / p.tox;

        // vbi = Vt * ln(Nch * Nsd / ni^2). With Nsd typically 1e20.
        let nsd = 1.0e20 * 1.0e6;
        let vbi = (vt_t * (npeak_m3 * nsd / (ni_use * ni_use)).ln()).max(0.5);

        // k1ox / k2ox: scale body effect by tox/toxm.
        let toxm = if p.toxm > 0.0 { p.toxm } else { p.tox };
        let k1ox = p.k1 * (p.tox / toxm);
        let k2ox = p.k2 * (p.tox / toxm);

        // theta0vb0 / thetaRout — pre-compute the DVT exponentials once.
        let l_t  = (consts::EPSSI * Xdep0 / cox).sqrt();
        let theta0vb0 = ((-p.dvt1  * 0.5 * leff / l_t).exp()
            + 2.0 * (-p.dvt1  * leff / l_t).exp()).max(0.0);
        let thetaRout  = ((-p.drout * 0.5 * leff / l_t).exp()
            + 2.0 * (-p.drout * leff / l_t).exp()).max(0.0);

        // Rds0 = rdsw / weff^wr
        let rds0 = if p.rdsw > 0.0 {
            p.rdsw / (weff * 1.0e6).powf(p.wr.max(0.0))
        } else {
            0.0
        };

        Self {
            mos_type: p.mos_type,
            temp,
            l_drawn,
            w_drawn,
            leff,
            weff,
            leffCV,
            weffCV,
            nf,
            cox,
            vt_t,
            phi,
            sqrtPhi,
            Xdep0,
            litl,
            vbi,
            k1ox,
            k2ox,
            vth0:    p.vth0,
            k1:      p.k1,
            k2:      p.k2,
            k3:      p.k3,
            k3b:     p.k3b,
            w0:      p.w0,
            nlx:     p.nlx,
            dvt0:    p.dvt0,
            dvt1:    p.dvt1,
            dvt2:    p.dvt2,
            dvt0w:   p.dvt0w,
            dvt1w:   p.dvt1w,
            dvt2w:   p.dvt2w,
            theta0vb0,
            thetaRout,
            eta0:    p.eta0,
            etab:    p.etab,
            voff:    p.voff,
            nfactor: p.nfactor,
            cdsc:    p.cdsc,
            cdscb:   p.cdscb,
            cdscd:   p.cdscd,
            cit:     p.cit,
            mobMod:  p.flags.mobMod,
            u0temp,
            ua,
            ub,
            uc,
            vsattemp,
            a0:      p.a0,
            ags:     p.ags,
            b0:      p.b0,
            b1:      p.b1,
            keta:    p.keta,
            a1:      p.a1,
            a2:      p.a2,
            rds0,
            prwg:    p.prwg,
            prwb:    p.prwb,
            pclm:    p.pclm,
            pdiblc1: p.pdiblc1,
            pdiblc2: p.pdiblc2,
            pdiblcb: p.pdiblcb,
            drout:   p.drout,
            dsub:    p.dsub,
            pscbe1:  p.pscbe1,
            pscbe2:  p.pscbe2,
            pvag:    p.pvag,
            delta:   p.delta,
            alpha0:  p.alpha0,
            alpha1:  p.alpha1,
            beta0:   p.beta0,
            vbm:     p.vbm,
            xj:      p.xj,
            tox:     p.tox,
        }
    }
}
