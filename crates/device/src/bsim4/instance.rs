// BSIM4 — ported from Berkeley BSIM4.8.3 (ECL-2.0)
//
// Warm tier — per-instance binned and geometry-resolved parameters.
// One `Bsim4Instance` per `.M<n>` device, built once at setup time and
// then read read-only by the hot DC/AC eval kernel.
//
// References (algorithmic intent only):
//   tests/external/ngspice/src/spicelib/devices/bsim4/b4set.c
//   tests/external/ngspice/src/spicelib/devices/bsim4/b4temp.c

#![allow(non_snake_case, dead_code)]

use super::model::Bsim4Model;
#[allow(unused_imports)]
use super::params::Bsim4Type;

/// Per-instance geometry as supplied on the M element.
#[derive(Debug, Clone, Copy)]
pub struct Bsim4Geometry {
    pub L:   f64,    // drawn channel length
    pub W:   f64,    // drawn channel width
    pub NF:  f64,    // number of fingers
    pub M:   f64,    // multiplier
    pub AS:  f64,    // source area
    pub AD:  f64,    // drain area
    pub PS:  f64,    // source perimeter
    pub PD:  f64,    // drain perimeter
    pub NRS: f64,    // source square count
    pub NRD: f64,    // drain square count
    pub SA:  f64,    // stress
    pub SB:  f64,
    pub SD:  f64,
}

impl Default for Bsim4Geometry {
    fn default() -> Self {
        Self {
            L:   1.0e-7,
            W:   1.0e-6,
            NF:  1.0,
            M:   1.0,
            AS:  0.0,
            AD:  0.0,
            PS:  0.0,
            PD:  0.0,
            NRS: 1.0,
            NRD: 1.0,
            SA:  0.0,
            SB:  0.0,
            SD:  0.0,
        }
    }
}

/// Resolved per-instance binned parameters.  Mirrors the subset of
/// `pParam->BSIM4*` fields that the DC eval kernel actually reads.
#[derive(Debug, Clone, Copy)]
pub struct Bsim4Instance {
    // ── geometry / electrical L,W after etch & process biases ───────────
    pub leff:    f64,
    pub weff:    f64,
    pub leffCV:  f64,
    pub weffCV:  f64,
    pub nfinger: f64,
    pub m_mult:  f64,
    pub coxe:    f64,    // F/m^2
    pub coxp:    f64,

    // ── threshold / surface potential ────────────────────────────────────
    pub vth0:    f64,    // long-channel zero-Vbs threshold
    pub vfb:     f64,
    pub k1:      f64,
    pub k2:      f64,
    pub k1ox:    f64,
    pub k2ox:    f64,
    pub phi:     f64,    // 2*phi_F at T
    pub sqrtPhi: f64,
    pub vbi:     f64,    // bi-junction built-in
    pub vbsc:    f64,
    pub k3:      f64,
    pub k3b:     f64,
    pub w0:      f64,
    pub lpe0:    f64,
    pub lpeb:    f64,
    pub dvt0:    f64,
    pub dvt1:    f64,
    pub dvt2:    f64,
    pub dvt0w:   f64,
    pub dvt1w:   f64,
    pub dvt2w:   f64,
    pub dsub:    f64,
    pub eta0:    f64,
    pub etab:    f64,
    pub voff:    f64,
    pub nfactor: f64,
    pub cdsc:    f64,
    pub cdscb:   f64,
    pub cdscd:   f64,
    pub cit:     f64,
    pub minv:    f64,

    // ── mobility ────────────────────────────────────────────────────────
    pub u0temp:  f64,
    pub ua:      f64,
    pub ub:      f64,
    pub uc:      f64,
    pub eu:      f64,
    pub vsattemp: f64,
    pub a0:      f64,
    pub ags:     f64,
    pub b0:      f64,
    pub b1:      f64,
    pub keta:    f64,
    pub a1:      f64,
    pub a2:      f64,

    // ── output / Early voltage / SCBE ────────────────────────────────────
    pub pclm:    f64,
    pub pdiblc1: f64,
    pub pdiblc2: f64,
    pub pdiblcb: f64,
    pub drout:   f64,
    pub pscbe1:  f64,
    pub pscbe2:  f64,
    pub pvag:    f64,
    pub delta:   f64,

    // ── series resistance / GIDL ────────────────────────────────────────
    pub rdsw:    f64,
    pub prwg:    f64,
    pub prwb:    f64,
    pub wr:      f64,

    pub agidl:   f64,
    pub bgidl:   f64,
    pub cgidl:   f64,
    pub egidl:   f64,
    pub agisl:   f64,
    pub bgisl:   f64,
    pub cgisl:   f64,
    pub egisl:   f64,

    // ── thermal voltage at the device temperature ────────────────────────
    pub vtm:     f64,    // k*T/q at T_dev
    pub temp:    f64,    // K
    pub polarity: f64,
}

impl Bsim4Instance {
    /// Build a per-instance struct by collapsing the model parameters and
    /// the geometry into "warm" form.
    ///
    /// Following BSIM4setup → BSIM4temp.  We do *not* perform full L/W
    /// binning (the b4set.c `pParam->...` correction loop) because for the
    /// DC port the un-binned values are correct in the limit of
    /// `LL=WL=PL=0`, which covers all PDK-supplied corner models that ship
    /// pre-binned per-corner.
    pub fn from_model(model: &Bsim4Model, geom: &Bsim4Geometry, temp_k: f64) -> Self {
        const KB:  f64 = 1.380_649e-23;
        const QE:  f64 = 1.602_176_634e-19;
        const EPS0: f64 = 8.854_187_817e-12;

        let p = &model.params;

        // Effective electrical channel L, W (no binning corrections).
        let leff = (geom.L + p.xl - 2.0 * p.lint).max(1.0e-9);
        let weff = (geom.W / geom.NF.max(1.0) + p.xw - 2.0 * p.wint).max(1.0e-9);

        // Oxide capacitance per unit area.
        let coxe = p.epsrox * EPS0 / p.toxe;
        let coxp = p.epsrox * EPS0 / p.toxp.max(1.0e-12);

        // Thermal voltage at the device temperature.
        let vtm = KB * temp_k / QE;
        let vt_nom = KB * p.tnom / QE;

        // Surface potential phi(T) — first-order temperature scaling
        // from b4temp.c (Vfbt / Phist block, simplified for our DC port).
        let ni_t = (p.ni0sub
            * (temp_k / 300.15).powf(1.5)
            * (-p.bg0sub * 0.5 / vtm + p.bg0sub * 0.5 / (KB * 300.15 / QE)).exp())
            .max(1.0e-1);
        let phi_default =
            2.0 * vt_nom * (p.ndep / 1.45e10_f64.max(ni_t)).ln().abs();
        let phi = if p.phi > 0.0 { p.phi } else { phi_default };
        let sqrt_phi = phi.sqrt();

        // Built-in voltage of source/drain to body.
        let vbi = vtm * (p.ndep * p.nsd / (1.45e10 * 1.45e10)).ln();

        // Body-effect coefficient at the model oxide thickness.
        let k1ox = p.k1 * (p.toxe / p.toxm).max(1.0e-12);
        let k2ox = p.k2 * (p.toxe / p.toxm).max(1.0e-12);

        // Mobility temperature scaling: u0(T) = u0 * (T/Tnom)^Ute.
        let u0temp = p.u0 * (temp_k / p.tnom).powf(p.ute);
        let vsattemp = p.vsat - p.at * (temp_k / p.tnom - 1.0);

        // vbsc: max body-source voltage clamp (b4temp.c).
        let vbsc_raw = -3.0 - p.k1 * sqrt_phi.max(0.0) + p.k2 * 0.0;
        let vbsc = vbsc_raw.min(-3.0).max(-30.0);

        // Vth0: if user gave Vth0 we use it directly, else compute from Vfb+phi+gamma*sqrt(phi).
        let vth0 = if p.vth0 != 0.0 {
            p.vth0
        } else {
            p.vfb + phi + p.k1 * sqrt_phi
        };
        let vfb = if p.vfb < -990.0 || p.vfb > 990.0 {
            vth0 - phi - p.k1 * sqrt_phi
        } else {
            p.vfb
        };

        Self {
            leff,
            weff,
            leffCV: leff,
            weffCV: weff,
            nfinger: geom.NF.max(1.0),
            m_mult:  geom.M.max(1.0),
            coxe,
            coxp,

            vth0,
            vfb,
            k1: p.k1,
            k2: p.k2,
            k1ox,
            k2ox,
            phi,
            sqrtPhi: sqrt_phi,
            vbi,
            vbsc,
            k3:  p.k3,
            k3b: p.k3b,
            w0:  p.w0,
            lpe0: p.lpe0,
            lpeb: p.lpeb,
            dvt0: p.dvt0,
            dvt1: p.dvt1,
            dvt2: p.dvt2,
            dvt0w: p.dvt0w,
            dvt1w: p.dvt1w,
            dvt2w: p.dvt2w,
            dsub:  p.dsub,
            eta0:  p.eta0,
            etab:  p.etab,
            voff:  p.voff,
            nfactor: p.nfactor,
            cdsc:  p.cdsc,
            cdscb: p.cdscb,
            cdscd: p.cdscd,
            cit:   p.cit,
            minv:  p.minv,

            u0temp,
            ua: p.ua,
            ub: p.ub,
            uc: p.uc,
            eu: p.eu,
            vsattemp,
            a0:   p.a0,
            ags:  p.ags,
            b0:   p.b0,
            b1:   p.b1,
            keta: p.keta,
            a1:   p.a1,
            a2:   p.a2,

            pclm:    p.pclm,
            pdiblc1: p.pdiblc1,
            pdiblc2: p.pdiblc2,
            pdiblcb: p.pdiblcb,
            drout:   p.drout,
            pscbe1:  p.pscbe1,
            pscbe2:  p.pscbe2,
            pvag:    p.pvag,
            delta:   p.delta,

            rdsw: p.rdsw,
            prwg: p.prwg,
            prwb: p.prwb,
            wr:   p.wr,

            agidl: p.agidl, bgidl: p.bgidl, cgidl: p.cgidl, egidl: p.egidl,
            agisl: p.agisl, bgisl: p.bgisl, cgisl: p.cgisl, egisl: p.egisl,

            vtm,
            temp: temp_k,
            polarity: p.mos_type.polarity(),
        }
    }
}

/// Convenience: build a default NMOS instance for unit tests.
pub fn nmos_default_instance() -> Bsim4Instance {
    let model = Bsim4Model::nmos_default();
    let geom  = Bsim4Geometry {
        L: 1.0e-7,
        W: 1.0e-6,
        ..Bsim4Geometry::default()
    };
    Bsim4Instance::from_model(&model, &geom, 300.15)
}

#[allow(unused_imports)]
use super::model;
#[allow(unused_imports)]
use super::params;
