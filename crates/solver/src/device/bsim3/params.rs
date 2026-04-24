// BSIM3 — ported from Berkeley BSIM3v3.3 (ECL-2.0)
//
// Hand port of the BSIM3v3.3 `.MODEL` parameter set.  This is the *cold
// tier*: the values here are exactly what the user typed in the SPICE
// netlist (after defaulting), with no L/W binning, no temperature
// scaling, and no derived constants applied yet.
//
// Reference (READ-ONLY for algorithmic intent):
//   tests/external/ngspice/src/spicelib/devices/bsim3/bsim3def.h
//   tests/external/ngspice/src/spicelib/devices/bsim3/b3.c
//   tests/external/ngspice/src/spicelib/devices/bsim3/b3mpar.c

#![allow(non_snake_case, dead_code)]

use incspice_core::ParamMap;

/// Polarity of a BSIM3 device: +1 for NMOS, -1 for PMOS.
///
/// Stored as `f64` in the hot path so it multiplies into bias equations
/// without branching.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Bsim3Type {
    Nmos,
    Pmos,
}

impl Bsim3Type {
    #[inline]
    pub fn polarity(self) -> f64 {
        match self {
            Bsim3Type::Nmos => 1.0,
            Bsim3Type::Pmos => -1.0,
        }
    }
}

/// Boolean flags / mode selectors per `.MODEL` card.
///
/// Mirrors the `int BSIM3xxxMod` fields in `bsim3def.h`.  Defaults follow
/// Berkeley `BSIM3checkModel` after `BSIM3mpar`.
#[derive(Debug, Clone, Copy)]
pub struct Bsim3ModelFlags {
    pub mobMod: i32,   // 1..3 mobility model (default 1)
    pub capMod: i32,   // 0..3 capacitance model (default 3)
    pub noiMod: i32,   // 1..4 noise model (default 1)
    pub paramChk: i32, // 0/1 paramater checking (default 1)
    pub binUnit: i32,  // 1=microns, 2=meters
    pub nqsMod: i32,   // 0/1 NQS model
}

impl Default for Bsim3ModelFlags {
    fn default() -> Self {
        // Berkeley BSIM3v3.3 defaults from b3mpar.c.
        Self {
            mobMod: 1,
            capMod: 3,
            noiMod: 1,
            paramChk: 1,
            binUnit: 1,
            nqsMod: 0,
        }
    }
}

/// Full BSIM3v3.3 `.MODEL` parameter card (cold tier).
///
/// Field names match the canonical Berkeley names lowercased.  L/W binning
/// prefixes (`l*`, `w*`, `p*`) are mirrored on the parameters that bin
/// against geometry.  Temperature pre-compute output and instance binning
/// resolution live in [`super::instance::Bsim3SizeParams`].
#[derive(Debug, Clone, Copy)]
pub struct Bsim3ModelParams {
    // ── identity / flags ─────────────────────────────────────────────────
    pub mos_type: Bsim3Type,
    pub flags: Bsim3ModelFlags,
    pub version: f64, // 3.3
    pub level: i32,   // 8 (also 49)

    // ── process / oxide / substrate ──────────────────────────────────────
    pub tnom: f64,   // K
    pub tox: f64,    // gate oxide thickness (m)
    pub toxm: f64,   // tox at which params extracted
    pub xj: f64,     // junction depth (m)
    pub gamma1: f64, // body-effect coeff for substrate
    pub gamma2: f64,
    pub npeak: f64, // channel doping (cm^-3) — 'nch'
    pub nsub: f64,  // substrate doping
    pub ngate: f64, // poly-gate doping
    pub vbm: f64,   // max applied body bias
    pub xt: f64,    // doping depth
    pub vbx: f64,   // body bias for full depletion
    pub phi: f64,   // 2*phi_F (auto-computed if not given)

    // ── threshold voltage ────────────────────────────────────────────────
    pub vth0: f64, // long-channel threshold @ Vbs=0
    pub k1: f64,   // 1st-order body-effect coeff
    pub k2: f64,   // 2nd-order body-effect
    pub k3: f64,   // narrow-width
    pub k3b: f64,
    pub w0: f64,
    pub nlx: f64,  // lateral non-uniform doping
    pub dvt0: f64, // SCE coeff
    pub dvt1: f64,
    pub dvt2: f64,
    pub dvt0w: f64, // narrow-width SCE
    pub dvt1w: f64,
    pub dvt2w: f64,
    pub drout: f64,   // DIBL exp T1 coefficient
    pub dsub: f64,    // DIBL exp coefficient
    pub eta0: f64,    // DIBL coefficient
    pub etab: f64,    // DIBL Vbs coefficient
    pub voff: f64,    // sub-threshold offset
    pub nfactor: f64, // sub-threshold swing factor
    pub cdsc: f64,    // S/D coupling factor
    pub cdscb: f64,
    pub cdscd: f64,
    pub cit: f64, // interface trap cap

    // ── mobility ────────────────────────────────────────────────────────
    pub u0: f64, // low-field mobility (m^2/V/s)
    pub ua: f64,
    pub ub: f64,
    pub uc: f64,
    pub vsat: f64, // saturation velocity
    pub a0: f64,   // Abulk param
    pub ags: f64,  // gate-bias Abulk dependence
    pub b0: f64,
    pub b1: f64,
    pub keta: f64,
    pub a1: f64,
    pub a2: f64,
    pub rdsw: f64, // S/D parasitic R per width
    pub prwg: f64,
    pub prwb: f64,
    pub wr: f64,

    // ── output / CLM / SCBE / DIBL2 ──────────────────────────────────────
    pub pclm: f64, // CLM coefficient
    pub pdiblc1: f64,
    pub pdiblc2: f64,
    pub pdiblcb: f64,
    pub pscbe1: f64,
    pub pscbe2: f64,
    pub pvag: f64,
    pub delta: f64, // Vds smoothing

    // ── source/drain junction diodes ─────────────────────────────────────
    pub js: f64,
    pub jsw: f64,
    pub pb: f64,
    pub nj: f64,
    pub xti: f64,
    pub mj: f64,
    pub pbsw: f64,
    pub mjsw: f64,
    pub pbswg: f64,
    pub mjswg: f64,
    pub cj: f64,
    pub cjsw: f64,
    pub cjswg: f64,
    pub ijth: f64, // junction current threshold for linearization

    // ── alpha/beta substrate impact ionization ───────────────────────────
    pub alpha0: f64,
    pub alpha1: f64,
    pub beta0: f64,

    // ── temperature scaling ─────────────────────────────────────────────
    pub kt1: f64,
    pub kt1l: f64,
    pub kt2: f64,
    pub ute: f64,
    pub ua1: f64,
    pub ub1: f64,
    pub uc1: f64,
    pub at: f64,
    pub prt: f64,
    pub tcj: f64,
    pub tpb: f64,
    pub tcjsw: f64,
    pub tpbsw: f64,
    pub tcjswg: f64,
    pub tpbswg: f64,

    // ── overlap / fringe / gate caps ─────────────────────────────────────
    pub cgso: f64,
    pub cgdo: f64,
    pub cgbo: f64,
    pub cgdl: f64,
    pub cgsl: f64,
    pub ckappa: f64,
    pub cf: f64,
    pub clc: f64,
    pub cle: f64,
    pub dlc: f64,
    pub dwc: f64,
    pub xpart: f64,
    pub elm: f64,
    pub vfbcv: f64,
    pub vfb: f64,
    pub acde: f64,
    pub moin: f64,
    pub noff: f64,
    pub voffcv: f64,

    // ── geometry / etch ──────────────────────────────────────────────────
    pub xl: f64,
    pub xw: f64,
    pub wint: f64,
    pub lint: f64,
    pub dwg: f64,
    pub dwb: f64,
    pub ll: f64,
    pub llc: f64,
    pub lln: f64,
    pub lw: f64,
    pub lwc: f64,
    pub lwn: f64,
    pub lwl: f64,
    pub lwlc: f64,
    pub wl: f64,
    pub wlc: f64,
    pub wln: f64,
    pub ww: f64,
    pub wwc: f64,
    pub wwn: f64,
    pub wwl: f64,
    pub wwlc: f64,
    pub lmin: f64,
    pub lmax: f64,
    pub wmin: f64,
    pub wmax: f64,
    pub rsh: f64, // S/D sheet resistance

    // ── flicker noise (parsed only) ──────────────────────────────────────
    pub noia: f64,
    pub noib: f64,
    pub noic: f64,
    pub em: f64,
    pub ef: f64,
    pub af: f64,
    pub kf: f64,
}

impl Default for Bsim3ModelParams {
    fn default() -> Self {
        // Berkeley BSIM3v3.3 default values from b3set.c / b3mpar.c.
        Self {
            mos_type: Bsim3Type::Nmos,
            flags: Bsim3ModelFlags::default(),
            version: 3.3,
            level: 8,

            tnom: 300.15,
            tox: 1.5e-8,
            toxm: 1.5e-8,
            xj: 1.5e-7,
            gamma1: 0.0, // computed from npeak if 0
            gamma2: 0.0, // computed from nsub if 0
            npeak: 1.7e17,
            nsub: 6.0e16,
            ngate: 0.0,
            vbm: -3.0,
            xt: 1.55e-7,
            vbx: 0.0, // computed from npeak if 0
            phi: 0.0, // computed in temp.rs

            vth0: 0.7,
            k1: 0.5,
            k2: 0.0,
            k3: 80.0,
            k3b: 0.0,
            w0: 2.5e-6,
            nlx: 1.74e-7,
            dvt0: 2.2,
            dvt1: 0.53,
            dvt2: -0.032,
            dvt0w: 0.0,
            dvt1w: 5.3e6,
            dvt2w: -0.032,
            drout: 0.56,
            dsub: 0.56,
            eta0: 0.08,
            etab: -0.07,
            voff: -0.08,
            nfactor: 1.0,
            cdsc: 2.4e-4,
            cdscb: 0.0,
            cdscd: 0.0,
            cit: 0.0,

            u0: 0.067, // NMOS default; 0.025 for PMOS
            ua: 2.25e-9,
            ub: 5.87e-19,
            uc: -4.65e-11,
            vsat: 8.0e4,
            a0: 1.0,
            ags: 0.0,
            b0: 0.0,
            b1: 0.0,
            keta: -0.047,
            a1: 0.0,
            a2: 1.0,
            rdsw: 0.0,
            prwg: 0.0,
            prwb: 0.0,
            wr: 1.0,

            pclm: 1.3,
            pdiblc1: 0.39,
            pdiblc2: 0.0086,
            pdiblcb: 0.0,
            pscbe1: 4.24e8,
            pscbe2: 1.0e-5,
            pvag: 0.0,
            delta: 0.01,

            js: 1.0e-4,
            jsw: 0.0,
            pb: 1.0,
            nj: 1.0,
            xti: 3.0,
            mj: 0.5,
            pbsw: 1.0,
            mjsw: 0.33,
            pbswg: 1.0,
            mjswg: 0.33,
            cj: 5.0e-4,
            cjsw: 5.0e-10,
            cjswg: 5.0e-10,
            ijth: 0.1,

            alpha0: 0.0,
            alpha1: 0.0,
            beta0: 30.0,

            kt1: -0.11,
            kt1l: 0.0,
            kt2: 0.022,
            ute: -1.5,
            ua1: 4.31e-9,
            ub1: -7.61e-18,
            uc1: -5.6e-11,
            at: 3.3e4,
            prt: 0.0,
            tcj: 0.0,
            tpb: 0.0,
            tcjsw: 0.0,
            tpbsw: 0.0,
            tcjswg: 0.0,
            tpbswg: 0.0,

            cgso: 0.0,
            cgdo: 0.0,
            cgbo: 0.0,
            cgdl: 0.0,
            cgsl: 0.0,
            ckappa: 0.6,
            cf: 0.0,
            clc: 1.0e-7,
            cle: 0.6,
            dlc: 0.0,
            dwc: 0.0,
            xpart: 0.0,
            elm: 5.0,
            vfbcv: -1.0,
            vfb: -1.0, // recomputed from vth0
            acde: 1.0,
            moin: 15.0,
            noff: 1.0,
            voffcv: 0.0,

            xl: 0.0,
            xw: 0.0,
            wint: 0.0,
            lint: 0.0,
            dwg: 0.0,
            dwb: 0.0,
            ll: 0.0,
            llc: 0.0,
            lln: 1.0,
            lw: 0.0,
            lwc: 0.0,
            lwn: 1.0,
            lwl: 0.0,
            lwlc: 0.0,
            wl: 0.0,
            wlc: 0.0,
            wln: 1.0,
            ww: 0.0,
            wwc: 0.0,
            wwn: 1.0,
            wwl: 0.0,
            wwlc: 0.0,
            lmin: 0.0,
            lmax: 1.0,
            wmin: 0.0,
            wmax: 1.0,
            rsh: 0.0,

            noia: 1.0e20,
            noib: 5.0e4,
            noic: -1.4e-12,
            em: 4.1e7,
            ef: 1.0,
            af: 1.0,
            kf: 0.0,
        }
    }
}

impl Bsim3ModelParams {
    /// Build a `Bsim3ModelParams` from a `ParamMap`. Anything missing
    /// falls back to the default. Aliased names (`vto` ↔ `vth0`,
    /// `nch` ↔ `npeak`) are resolved here.
    pub fn from_map(map: &ParamMap, mos_type: Bsim3Type) -> Self {
        let d = Bsim3ModelParams::default();
        let g = |k: &str, dv: f64| map.get_or(k, dv);
        let g2 = |k1: &str, k2: &str, dv: f64| map.get(k1).or_else(|| map.get(k2)).unwrap_or(dv);
        let gi = |k: &str, dv: i32| map.get(k).map(|v| v as i32).unwrap_or(dv);

        // PMOS gets a different default low-field mobility.
        let u0_default = if matches!(mos_type, Bsim3Type::Pmos) {
            0.025
        } else {
            d.u0
        };

        let mut p = d;
        p.mos_type = mos_type;

        p.flags.mobMod = gi("mobmod", d.flags.mobMod);
        p.flags.capMod = gi("capmod", d.flags.capMod);
        p.flags.noiMod = gi("noimod", d.flags.noiMod);
        p.flags.paramChk = gi("paramchk", d.flags.paramChk);
        p.flags.binUnit = gi("binunit", d.flags.binUnit);
        p.flags.nqsMod = gi("nqsmod", d.flags.nqsMod);

        // Validate sub-model mode selectors, falling back to safe
        // defaults when the user supplies an out-of-range value.
        if !(1..=3).contains(&p.flags.mobMod) {
            log::warn!(
                "BSIM3: mobMod={} out of range [1,3], falling back to default {}",
                p.flags.mobMod,
                d.flags.mobMod
            );
            p.flags.mobMod = d.flags.mobMod;
        }
        if !(0..=3).contains(&p.flags.capMod) {
            log::warn!(
                "BSIM3: capMod={} out of range [0,3], falling back to default {}",
                p.flags.capMod,
                d.flags.capMod
            );
            p.flags.capMod = d.flags.capMod;
        }
        if !(1..=4).contains(&p.flags.noiMod) {
            log::warn!(
                "BSIM3: noiMod={} out of range [1,4], falling back to default {}",
                p.flags.noiMod,
                d.flags.noiMod
            );
            p.flags.noiMod = d.flags.noiMod;
        }

        p.version = g("version", d.version);
        p.level = gi("level", d.level);

        p.tnom = g2("tnom", "tref", d.tnom);
        p.tox = g("tox", d.tox);
        p.toxm = g("toxm", p.tox);
        p.xj = g("xj", d.xj);
        p.gamma1 = g("gamma1", d.gamma1);
        p.gamma2 = g("gamma2", d.gamma2);
        p.npeak = g2("nch", "npeak", d.npeak);
        p.nsub = g("nsub", d.nsub);
        p.ngate = g("ngate", d.ngate);
        p.vbm = g("vbm", d.vbm);
        p.xt = g("xt", d.xt);
        p.vbx = g("vbx", d.vbx);
        p.phi = g("phi", 0.0);

        p.vth0 = g2("vth0", "vto", d.vth0);
        p.k1 = g("k1", d.k1);
        p.k2 = g("k2", d.k2);
        p.k3 = g("k3", d.k3);
        p.k3b = g("k3b", d.k3b);
        p.w0 = g("w0", d.w0);
        p.nlx = g("nlx", d.nlx);
        p.dvt0 = g("dvt0", d.dvt0);
        p.dvt1 = g("dvt1", d.dvt1);
        p.dvt2 = g("dvt2", d.dvt2);
        p.dvt0w = g("dvt0w", d.dvt0w);
        p.dvt1w = g("dvt1w", d.dvt1w);
        p.dvt2w = g("dvt2w", d.dvt2w);
        p.drout = g("drout", d.drout);
        p.dsub = g("dsub", p.drout);
        p.eta0 = g("eta0", d.eta0);
        p.etab = g("etab", d.etab);
        p.voff = g("voff", d.voff);
        p.nfactor = g("nfactor", d.nfactor);
        p.cdsc = g("cdsc", d.cdsc);
        p.cdscb = g("cdscb", d.cdscb);
        p.cdscd = g("cdscd", d.cdscd);
        p.cit = g("cit", d.cit);

        p.u0 = g("u0", u0_default);
        p.ua = g("ua", d.ua);
        p.ub = g("ub", d.ub);
        p.uc = g("uc", d.uc);
        p.vsat = g("vsat", d.vsat);
        p.a0 = g("a0", d.a0);
        p.ags = g("ags", d.ags);
        p.b0 = g("b0", d.b0);
        p.b1 = g("b1", d.b1);
        p.keta = g("keta", d.keta);
        p.a1 = g("a1", d.a1);
        p.a2 = g("a2", d.a2);
        p.rdsw = g("rdsw", d.rdsw);
        p.prwg = g("prwg", d.prwg);
        p.prwb = g("prwb", d.prwb);
        p.wr = g("wr", d.wr);

        p.pclm = g("pclm", d.pclm);
        p.pdiblc1 = g("pdiblc1", d.pdiblc1);
        p.pdiblc2 = g("pdiblc2", d.pdiblc2);
        p.pdiblcb = g("pdiblcb", d.pdiblcb);
        p.pscbe1 = g("pscbe1", d.pscbe1);
        p.pscbe2 = g("pscbe2", d.pscbe2);
        p.pvag = g("pvag", d.pvag);
        p.delta = g("delta", d.delta);

        p.js = g("js", d.js);
        p.jsw = g("jsw", d.jsw);
        p.pb = g("pb", d.pb);
        p.nj = g("nj", d.nj);
        p.xti = g("xti", d.xti);
        p.mj = g("mj", d.mj);
        p.pbsw = g("pbsw", d.pbsw);
        p.mjsw = g("mjsw", d.mjsw);
        p.pbswg = g("pbswg", p.pbsw);
        p.mjswg = g("mjswg", p.mjsw);
        p.cj = g("cj", d.cj);
        p.cjsw = g("cjsw", d.cjsw);
        p.cjswg = g("cjswg", d.cjswg);
        p.ijth = g("ijth", d.ijth);

        p.alpha0 = g("alpha0", d.alpha0);
        p.alpha1 = g("alpha1", d.alpha1);
        p.beta0 = g("beta0", d.beta0);

        p.kt1 = g("kt1", d.kt1);
        p.kt1l = g("kt1l", d.kt1l);
        p.kt2 = g("kt2", d.kt2);
        p.ute = g("ute", d.ute);
        p.ua1 = g("ua1", d.ua1);
        p.ub1 = g("ub1", d.ub1);
        p.uc1 = g("uc1", d.uc1);
        p.at = g("at", d.at);
        p.prt = g("prt", d.prt);

        p.cgso = g("cgso", d.cgso);
        p.cgdo = g("cgdo", d.cgdo);
        p.cgbo = g("cgbo", d.cgbo);

        p.xl = g("xl", d.xl);
        p.xw = g("xw", d.xw);
        p.wint = g("wint", d.wint);
        p.lint = g("lint", d.lint);
        p.dwg = g("dwg", d.dwg);
        p.dwb = g("dwb", d.dwb);
        p.rsh = g("rsh", d.rsh);

        // Log critical parameters that are using defaults (debug level).
        if map.get("tox").is_none() {
            log::debug!("BSIM3: tox not specified, using default {:.3e} m", p.tox);
        }
        if map.get("vth0").is_none() && map.get("vto").is_none() {
            log::debug!("BSIM3: vth0 not specified, using default {:.3} V", p.vth0);
        }
        if map.get("u0").is_none() {
            log::debug!("BSIM3: u0 not specified, using default {:.4} m^2/V/s", p.u0);
        }
        if map.get("vsat").is_none() {
            log::debug!("BSIM3: vsat not specified, using default {:.3e} m/s", p.vsat);
        }
        if map.get("nch").is_none() && map.get("npeak").is_none() {
            log::debug!("BSIM3: nch/npeak not specified, using default {:.3e} cm^-3", p.npeak);
        }
        if map.get("rdsw").is_none() {
            log::debug!("BSIM3: rdsw not specified, using default {:.1} ohm*um", p.rdsw);
        }

        p
    }
}
