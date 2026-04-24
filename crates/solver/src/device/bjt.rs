use incspice_core::{DeviceKind, ParamMap};
use smallvec::{SmallVec, smallvec};

use crate::device::eval::{DeviceEval, DeviceModel};

/// Bipolar Junction Transistor — full SPICE Gummel-Poon model (NPN and PNP).
///
/// Pin layout (3 terminals):
///   Pin 0 = collector
///   Pin 1 = base
///   Pin 2 = emitter
///
/// For NPN: junction voltages are Vbe = Vb - Ve, Vbc = Vb - Vc.
/// For PNP: voltages are flipped (polarity = -1) so the same equations hold.
///
/// # Model levels
///
/// `level = 0` — simplified Ebers-Moll (no Early effect, no high-injection,
///               no leakage). Activated by `.MODEL NPN LEVEL=0` or when none
///               of the Gummel-Poon extension parameters are specified.
///
/// `level = 1` (default) — full Gummel-Poon transport equations (DC, intrinsic):
///
///   Forward and reverse transport currents:
///     If  = Is * (exp(Vbe / (Nf*Vt)) - 1)          — BE forward injection
///     Ir  = Is * (exp(Vbc / (Nr*Vt)) - 1)          — BC reverse injection
///
///   Recombination leakage:
///     Ibe_rec = Ise * (exp(Vbe / (Ne*Vt)) - 1)     — BE recombination
///     Ibc_rec = Isc * (exp(Vbc / (Nc*Vt)) - 1)     — BC recombination
///
///   Base charge factor (Early + high-injection Webster effect):
///     q1  = 1 / (1 - Vbc/Vaf - Vbe/Var)
///     q2  = If/Ikf + Ir/Ikr
///     qb  = (q1/2) * (1 + sqrt(1 + 4*q2))
///
///   Terminal currents:
///     Icc            = (If - Ir) / qb              — transport current
///     Ibe            = If/Bf + Ibe_rec              — BE current
///     Ibc            = Ir/Br + Ibc_rec              — BC current
///     Ic_terminal    = Icc - Ibc
///     Ib_terminal    = Ibe + Ibc
///     Ie_terminal    = -(Icc + Ibe)
///
/// # Full Gummel-Poon parameter set (ngspice bjtdefs.h §2.4):
///
/// Core transport:
///   `is`   — saturation current (default 1e-16)
///   `bf`   — forward beta (default 100)
///   `nf`   — forward emission coefficient (default 1.0)
///   `vaf`  — forward Early voltage (default 1e30 ≈ ∞)
///   `ikf`  — forward knee current (default 1e30 ≈ ∞)
///   `ise`  — BE leakage saturation current (default 0)
///   `ne`   — BE leakage emission coefficient (default 1.5)
///   `br`   — reverse beta (default 1)
///   `nr`   — reverse emission coefficient (default 1.0)
///   `var`  — reverse Early voltage (default 1e30 ≈ ∞)
///   `ikr`  — reverse knee current (default 1e30 ≈ ∞)
///   `isc`  — BC leakage saturation current (default 0)
///   `nc`   — BC leakage emission coefficient (default 2.0)
///
/// Resistances (accepted, deferred to Phase 2 internal-node model):
///   `rb`   — zero-bias base resistance (default 0)
///   `irb`  — current where Rb falls to (Rb+Rbm)/2 (default ∞)
///   `rbm`  — minimum base resistance (default Rb)
///   `re`   — emitter resistance (default 0)
///   `rc`   — collector resistance (default 0)
///
/// Capacitance / transit time (accepted, deferred DC-only wave):
///   `cje`  — BE zero-bias depletion cap (default 0)
///   `vje`  — BE junction potential (default 0.75)
///   `mje`  — BE junction grading exponent (default 0.33)
///   `tf`   — ideal forward transit time (default 0)
///   `xtf`  — transit-time bias coeff (default 0)
///   `vtf`  — transit-time dependence on Vbc (default ∞)
///   `itf`  — transit-time high-injection parameter (default 0)
///   `ptf`  — excess phase at 1/(2π·Tf) Hz, degrees (default 0)
///   `cjc`  — BC zero-bias depletion cap (default 0)
///   `vjc`  — BC junction potential (default 0.75)
///   `mjc`  — BC junction grading exponent (default 0.33)
///   `xcjc` — fraction of Cjc connected to internal base (default 1)
///   `tr`   — ideal reverse transit time (default 0)
///   `cjs`  — C-S zero-bias junction cap (default 0)
///   `vjs`  — substrate junction potential (default 0.75)
///   `mjs`  — substrate junction grading exponent (default 0)
///
/// Temperature / noise:
///   `xtb`  — forward/reverse beta temperature exponent (default 0)
///   `eg`   — bandgap energy eV (default 1.11)
///   `xti`  — IS temperature exponent (default 3.0)
///   `kf`   — flicker noise coefficient (default 0)
///   `af`   — flicker noise exponent (default 1)
///   `fc`   — depletion-cap forward-bias linearization coefficient (default 0.5)
///   `vt`   — thermal voltage (default 0.02585 ≈ 26 mV at 300 K)
///   `tnom` — nominal temperature K (default 300.15; deferred)
///
/// Level selector:
///   `level` — 0 = Ebers-Moll fallback, 1 = full Gummel-Poon (default 1)
///
/// TODO Phase 2 transient: compute junction charges q_be, q_bc, q_bx, q_sub
///   from cje/vje/mje, cjc/vjc/mjc/xcjc, cjs/vjs/mjs, tf/tr/xtf/vtf/itf/ptf, fc
///   and populate q[] and C[] entries.
#[derive(Debug, Clone, Copy)]
pub struct Bjt {
    /// +1.0 for NPN, -1.0 for PNP.
    pub polarity: f64,
}

impl Bjt {
    pub const fn npn() -> Self {
        Self { polarity: 1.0 }
    }

    pub const fn pnp() -> Self {
        Self { polarity: -1.0 }
    }

    /// Default thermal voltage at ~300 K.
    const DEFAULT_VT: f64 = 0.02585;
    /// Per-junction GMIN for numerical stability (matches ngspice device-level GMIN).
    const GMIN: f64 = 1e-12;

    /// Boltzmann constant (J/K).
    const KB: f64 = 1.380_649e-23;

    /// Elementary charge (C).
    const Q: f64 = 1.602_176_634e-19;

    #[inline]
    fn temperature_scale_is(is_nom: f64, temp: f64, tnom: f64, xti: f64, eg: f64, nf: f64) -> f64 {
        if (temp - tnom).abs() < 1e-6 {
            return is_nom;
        }
        let vt_t = Self::KB * temp / Self::Q;
        let ratio = temp / tnom;
        is_nom * ratio.powf(xti / nf) * ((eg / nf) * (ratio - 1.0) / vt_t).exp()
    }

    #[inline]
    fn temperature_scale_beta(beta: f64, temp: f64, tnom: f64, xtb: f64) -> f64 {
        if (temp - tnom).abs() < 1e-6 || xtb == 0.0 {
            return beta;
        }
        beta * (temp / tnom).powf(xtb)
    }

    /// Compute junction current and conductance with SPICE voltage limiting.
    ///
    /// Above `vcrit + 10*nvt`, the exponential is replaced by a tangent-line
    /// linearization so Newton steps remain well-conditioned. At convergence the
    /// solution is always in the accurate exponential region.
    ///
    /// Returns `(current, conductance)` where `current = is*(exp(v/nvt) - 1)`.
    #[inline]
    fn exp_iv(v: f64, is: f64, nvt: f64) -> (f64, f64) {
        // Critical voltage: vcrit = nvt * ln(nvt / (sqrt(2) * is))
        let vcrit = nvt * (nvt / (std::f64::consts::SQRT_2 * is.max(1e-300))).ln();
        let vlimit = vcrit + 10.0 * nvt;
        if v <= vlimit {
            let e = (v / nvt).exp();
            (is * (e - 1.0), is * e / nvt)
        } else {
            let e_lim = (vlimit / nvt).exp();
            let g = is * e_lim / nvt;
            let i = is * (e_lim - 1.0) + g * (v - vlimit);
            (i, g)
        }
    }

    /// Ebers-Moll evaluation (level = 0): no Early effect, no high-injection,
    /// no leakage currents. Returns the same DeviceEval layout as GP level 1.
    fn eval_ebers_moll(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let is = params.get_or("is", 1e-16);
        let bf = params.get_or("bf", 100.0);
        let nf = params.get_or("nf", 1.0);
        let br = params.get_or("br", 1.0);
        let nr = params.get_or("nr", 1.0);
        let vt = params.get_or("vt", Self::DEFAULT_VT);

        let nf_vt = nf * vt;
        let nr_vt = nr * vt;
        let p = self.polarity;

        let vc = voltages[0];
        let vb = voltages[1];
        let ve = voltages[2];
        let vbe = p * (vb - ve);
        let vbc = p * (vb - vc);

        let (i_f, g_f) = Self::exp_iv(vbe, is, nf_vt);
        let (i_r, g_r) = Self::exp_iv(vbc, is, nr_vt);

        let inv_bf = 1.0 / bf;
        let inv_br = 1.0 / br;

        // Ebers-Moll: qb = 1 (no Early, no high-injection)
        let icc = i_f - i_r;
        let ibe = i_f * inv_bf;
        let ibc = i_r * inv_br;

        let ic_intrinsic = icc - ibc;
        let ib_intrinsic = ibe + ibc;
        let ie_intrinsic = -(icc + ibe);

        // Jacobian w.r.t. (vbe, vbc)
        let dic_dvbe = g_f;
        let dic_dvbc = -g_r - g_r * inv_br;
        let dib_dvbe = g_f * inv_bf;
        let dib_dvbc = g_r * inv_br;
        let die_dvbe = -(g_f + g_f * inv_bf);
        let die_dvbc = g_r;

        let gmin = Self::GMIN;
        let ic_gmin = gmin * (vc - vb);
        let ib_gmin = gmin * (vb - vc) + gmin * (vb - ve);
        let ie_gmin = gmin * (ve - vb);

        let ic = p * ic_intrinsic + ic_gmin;
        let ib = p * ib_intrinsic + ib_gmin;
        let ie = p * ie_intrinsic + ie_gmin;

        let dic_dvc = -dic_dvbc;
        let dic_dvb = dic_dvbe + dic_dvbc;
        let dic_dve = -dic_dvbe;
        let dib_dvc = -dib_dvbc;
        let dib_dvb = dib_dvbe + dib_dvbc;
        let dib_dve = -dib_dvbe;
        let die_dvc = -die_dvbc;
        let die_dvb = die_dvbe + die_dvbc;
        let die_dve = -die_dvbe;

        DeviceEval {
            g: smallvec![ic, ib, ie],
            q: smallvec![0.0, 0.0, 0.0],
            G: smallvec![
                (0, 0, dic_dvc + gmin),
                (0, 1, dic_dvb - gmin),
                (0, 2, dic_dve),
                (1, 0, dib_dvc - gmin),
                (1, 1, dib_dvb + 2.0 * gmin),
                (1, 2, dib_dve - gmin),
                (2, 0, die_dvc),
                (2, 1, die_dvb - gmin),
                (2, 2, die_dve + gmin),
            ],
            C: SmallVec::new(),
            rhs: SmallVec::new(),
        }
    }
}

impl Bjt {
    /// Stamp extrinsic series resistances (RB, RE, RC) as conductance entries
    /// between external pins (0=C,1=B,2=E) and internal pins (3=C',4=B',5=E').
    ///
    /// Returns a `DeviceEval` that contains:
    ///   - The intrinsic GP core result (re-indexed to use internal pins 3,4,5)
    ///   - Resistor conductance entries between external and internal pin pairs
    ///
    /// If `voltages.len() < 6`, falls back to the 3-terminal eval (no internal nodes).
    fn eval_with_extrinsic(
        &self,
        voltages: &[f64],
        params: &ParamMap,
        rb: f64,
        re: f64,
        rc: f64,
    ) -> DeviceEval {
        // If fewer than 7 voltages, internal nodes haven't been wired yet.
        // Fall back to 3-terminal so the circuit still converges.
        // Pin layout post-B001: 0=extC, 1=extB, 2=extE, 3=substrate, 4=intC', 5=intB', 6=intE'
        if voltages.len() < 7 {
            return self.eval_intrinsic_3pin(voltages, params);
        }

        // External pin voltages (from circuit nodes).
        let vc_ext = voltages[0];
        let vb_ext = voltages[1];
        let ve_ext = voltages[2];
        // Internal pin voltages (internal nodes in MNA).
        let vc_int = voltages[4];
        let vb_int = voltages[5];
        let ve_int = voltages[6];

        // Evaluate the GP core using internal node voltages.
        // eval_gp_core returns:
        //   core — DeviceEval with all charges EXCEPT CJC
        //   c_bc_dep — total CJC capacitance (before xcjc split)
        //   q_cjc — total CJC charge (before xcjc split)
        let (core, c_bc_dep, q_cjc) = self.eval_gp_core(&[vc_int, vb_int, ve_int], params);
        let p = self.polarity;

        // Conductances for extrinsic resistors: G = 1/R.
        let gc = if rc > 0.0 { 1.0 / rc } else { 0.0 };
        let gb = if rb > 0.0 { 1.0 / rb } else { 0.0 };
        let ge = if re > 0.0 { 1.0 / re } else { 0.0 };

        // When extrinsic resistance is zero, short ext to int via large conductance
        // to prevent internal nodes from floating in the MNA matrix.
        const GSHORT: f64 = 1e9;
        let gc_eff = if gc > 0.0 { gc } else { GSHORT };
        let gb_eff = if gb > 0.0 { gb } else { GSHORT };
        let ge_eff = if ge > 0.0 { ge } else { GSHORT };

        // Currents through the extrinsic resistors (flowing from ext to int).
        let ir_c = (vc_ext - vc_int) * gc_eff;
        let ir_b = (vb_ext - vb_int) * gb_eff;
        let ir_e = (ve_ext - ve_int) * ge_eff;

        // Build combined 7-terminal DeviceEval.
        let mut g6_jac: SmallVec<[(u8, u8, f64); 8]> = SmallVec::new();

        // RC: pins 0 (ext_C) and 4 (int_C') — always stamp (GSHORT when rc=0)
        g6_jac.push((0, 0, gc_eff));
        g6_jac.push((0, 4, -gc_eff));
        g6_jac.push((4, 0, -gc_eff));
        g6_jac.push((4, 4, gc_eff));
        // RB: pins 1 (ext_B) and 5 (int_B') — always stamp (GSHORT when rb=0)
        g6_jac.push((1, 1, gb_eff));
        g6_jac.push((1, 5, -gb_eff));
        g6_jac.push((5, 1, -gb_eff));
        g6_jac.push((5, 5, gb_eff));
        // RE: pins 2 (ext_E) and 6 (int_E') — always stamp (GSHORT when re=0)
        g6_jac.push((2, 2, ge_eff));
        g6_jac.push((2, 6, -ge_eff));
        g6_jac.push((6, 2, -ge_eff));
        g6_jac.push((6, 6, ge_eff));

        // Append GP core Jacobian re-indexed from (0,1,2) → (4,5,6).
        for (row, col, val) in &core.G {
            g6_jac.push((row + 4, col + 4, *val));
        }

        // ── Charge / capacitance — Fix 4.1: proper XCJC separation ───────────
        //
        // eval_gp_core returns C[] entries for TF, TR, CJE, CJS (all intrinsic
        // charges) but NOT for CJC.  CJC is returned separately as c_bc_dep so
        // we can apply the XCJC split correctly without contaminating TF/TR.
        //
        // ngspice reference (bjtacld.c:65-70): stamps 6 separate capacitive
        // quantities — CJE, CJC internal, CJC external, CJS, TF diffusion,
        // and TF cross-coupling — each independently.  Our separation matches.
        let xcjc = params.get_or("xcjc", 1.0).clamp(0.0, 1.0);

        // q[] for 7 pins.
        let mut q6: SmallVec<[f64; 8]> = smallvec![0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
        // Re-index core q (which excludes CJC) from (0,1,2) → (4,5,6).
        for (i, &qval) in core.q.iter().enumerate() {
            q6[i + 4] += qval;
        }
        // Add CJC charge with XCJC split:
        //   xcjc fraction: internal base (pin 5) and internal collector (pin 4)
        //   (1-xcjc) fraction: external base (pin 1) and internal collector (pin 4)
        let q_cjc_int = q_cjc * xcjc;
        let q_cjc_ext = q_cjc * (1.0 - xcjc);
        q6[5] += p * q_cjc_int;   // internal base: +Q_cjc_int
        q6[4] += p * (-q_cjc_int); // internal collector: -Q_cjc_int (from int fraction)
        q6[1] += p * q_cjc_ext;   // external base: +Q_cjc_ext
        q6[4] += p * (-q_cjc_ext); // internal collector: -Q_cjc_ext (from ext fraction)

        // Build C Jacobian for 7 terminals.
        let mut c6_jac: SmallVec<[(u8, u8, f64); 16]> = SmallVec::new();

        // All core.C entries (TF, TR, CJE, CJS) go entirely to internal pins.
        // These are intrinsic charges that always reside at the internal junctions;
        // XCJC does NOT apply to them (Fix 4.1).
        for &(row, col, val) in &core.C {
            c6_jac.push((row + 4, col + 4, val));
        }

        // CJC capacitance with XCJC split (ngspice bjtacld.c:66-67):
        //   xcjc fraction: internal base (pin 5) ↔ internal collector (pin 4)
        //   (1-xcjc) fraction: external base (pin 1) ↔ internal collector (pin 4)
        let c_cjc_int = c_bc_dep * xcjc;
        let c_cjc_ext = c_bc_dep * (1.0 - xcjc);
        if c_cjc_int != 0.0 {
            c6_jac.push((5, 5, c_cjc_int));    // dQ_intB/dV_intB
            c6_jac.push((5, 4, -c_cjc_int));   // dQ_intB/dV_intC
            c6_jac.push((4, 5, -c_cjc_int));   // dQ_intC/dV_intB
            c6_jac.push((4, 4, c_cjc_int));    // dQ_intC/dV_intC
        }
        if c_cjc_ext != 0.0 {
            c6_jac.push((1, 1, c_cjc_ext));    // dQ_extB/dV_extB
            c6_jac.push((1, 4, -c_cjc_ext));   // dQ_extB/dV_intC
            c6_jac.push((4, 1, -c_cjc_ext));   // dQ_intC/dV_extB
            c6_jac.push((4, 4, c_cjc_ext));    // dQ_intC/dV_intC
        }

        DeviceEval {
            g: smallvec![
                ir_c,
                ir_b,
                ir_e,
                0.0,              // substrate (pin 3) — no extrinsic resistor
                core.g[0] - ir_c, // int_C' (pin 4)
                core.g[1] - ir_b, // int_B' (pin 5)
                core.g[2] - ir_e, // int_E' (pin 6)
            ],
            q: q6,
            G: g6_jac,
            C: c6_jac,
            rhs: SmallVec::new(),
        }
    }

    /// 3-terminal intrinsic GP evaluation (no extrinsic resistances).
    fn eval_intrinsic_3pin(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let level = params.get_or("level", 1.0) as u32;
        if level == 0 {
            return self.eval_ebers_moll(voltages, params);
        }
        self.eval_gp(voltages, params)
    }

    /// Full Gummel-Poon evaluation (level=1).
    ///
    /// Returns a `DeviceEval` that includes **all** capacitive entries except CJC.
    /// CJC (base-collector junction depletion capacitance) is returned separately
    /// as `c_bc_dep` so that callers can apply the XCJC split correctly.
    ///
    /// The returned `q[]` likewise excludes the CJC charge contribution `q_cjc`;
    /// callers must add it to the appropriate pins.
    fn eval_gp_core(&self, voltages: &[f64], params: &ParamMap) -> (DeviceEval, f64, f64) {
        // ── Parameter extraction ──────────────────────────────────────────────
        let is = params.get_or("is", 1e-16); // saturation current
        let bf = params.get_or("bf", 100.0); // forward beta
        let nf = params.get_or("nf", 1.0); // forward emission coefficient
        let vaf = params.get("vaf").or_else(|| params.get("va")).unwrap_or(1e30); // forward Early voltage
        let ikf = params.get("ikf").or_else(|| params.get("ik")).unwrap_or(1e30); // forward knee current (high-injection)
        let ise = params.get_or("ise", 0.0); // BE leakage saturation current
        let ne = params.get_or("ne", 1.5); // BE leakage emission coefficient
        let br = params.get_or("br", 1.0); // reverse beta
        let nr = params.get_or("nr", 1.0); // reverse emission coefficient
        let var = params.get("var").or_else(|| params.get("vb")).unwrap_or(1e30); // reverse Early voltage
        let ikr = params.get("ikr").or_else(|| params.get("ik_r")).unwrap_or(1e30); // reverse knee current
        let isc = params.get_or("isc", 0.0); // BC leakage saturation current
        let nc = params.get_or("nc", 2.0); // BC leakage emission coefficient
        // Accept remaining GP parameters (consumed to avoid parse errors).
        let _rb = params.get_or("rb", 0.0);
        let _irb = params.get_or("irb", 1e30);
        let _rbm = params.get_or("rbm", _rb);
        let _re = params.get_or("re", 0.0);
        let _rc = params.get_or("rc", 0.0);
        let cje = params.get_or("cje", 0.0);
        let vje = params.get("vje").or_else(|| params.get("pe")).unwrap_or(0.75);
        let mje = params.get("mje").or_else(|| params.get("me")).unwrap_or(0.33);
        // Transit-time parameters (active for charge stamping).
        let tf = params.get_or("tf", 0.0);
        let xtf = params.get_or("xtf", 0.0);
        let vtf = params.get_or("vtf", 1e30);
        let itf = params.get_or("itf", 0.0);
        let ptf = params.get_or("ptf", 0.0);
        let cjc = params.get_or("cjc", 0.0);
        let vjc = params.get("vjc").or_else(|| params.get("pc")).unwrap_or(0.75);
        let mjc = params.get("mjc").or_else(|| params.get("mc")).unwrap_or(0.33);
        let xcjc = params.get_or("xcjc", 1.0);
        let tr = params.get_or("tr", 0.0);
        // CJS — collector-substrate capacitance (active: stamped between C and ground).
        let cjs = params.get("cjs").or_else(|| params.get("ccs")).unwrap_or(0.0);
        let vjs = params.get_or("vjs", 0.75);
        let mjs = params.get_or("mjs", 0.0);
        let xtb = params.get_or("xtb", 0.0);
        let eg = params.get_or("eg", 1.11);
        let xti = params.get_or("xti", 3.0);
        let _kf = params.get_or("kf", 0.0);
        let _af = params.get_or("af", 1.0);
        let fc = params.get_or("fc", 0.5);
        let temp = params.get_or("temp", 300.15);
        let tnom = params.get_or("tnom", 300.15);

        // Vt(T) = kT/q; honour explicit "vt" override or derive from temp.
        let vt = if params.contains("vt") {
            params.get_or("vt", Self::DEFAULT_VT)
        } else if params.contains("temp") {
            Self::KB * temp / Self::Q
        } else {
            Self::DEFAULT_VT
        };

        // Temperature-scale Is, Bf, Br, Ise, Isc.
        let is = Self::temperature_scale_is(is, temp, tnom, xti, eg, nf);
        let bf = Self::temperature_scale_beta(bf, temp, tnom, xtb);
        let br = Self::temperature_scale_beta(br, temp, tnom, xtb);
        let ise = if ise > 0.0 {
            Self::temperature_scale_is(ise, temp, tnom, xti, eg, ne)
        } else {
            0.0
        };
        let isc = if isc > 0.0 {
            Self::temperature_scale_is(isc, temp, tnom, xti, eg, nc)
        } else {
            0.0
        };

        // Pre-compute scaled thermal voltages.
        let nf_vt = nf * vt;
        let nr_vt = nr * vt;
        let ne_vt = ne * vt;
        let nc_vt = nc * vt;

        let p = self.polarity;

        // ── Junction voltages ─────────────────────────────────────────────────
        // NPN: vbe = Vb - Ve,  vbc = Vb - Vc  (natural forward-bias polarity)
        // PNP: flip sign so the same transport equations apply to both types.
        let vc = voltages[0];
        let vb = voltages[1];
        let ve = voltages[2];
        let vbe = p * (vb - ve);
        let vbc = p * (vb - vc);

        // ── Forward/reverse transport (main junction currents) ────────────────
        // If and Ir use Is directly; early-effect modifies transport via qb.
        let (i_f, g_f) = Self::exp_iv(vbe, is, nf_vt);
        let (i_r, g_r) = Self::exp_iv(vbc, is, nr_vt);

        // ── Leakage recombination terms ───────────────────────────────────────
        let (ibe_rec, gbe_rec) = if ise > 0.0 {
            Self::exp_iv(vbe, ise, ne_vt)
        } else {
            (0.0, 0.0)
        };
        let (ibc_rec, gbc_rec) = if isc > 0.0 {
            Self::exp_iv(vbc, isc, nc_vt)
        } else {
            (0.0, 0.0)
        };

        // ── Base charge factor qb (Early effect + Webster high-injection) ─────
        //
        //   q1 = 1 / (1 - vbc/Vaf - vbe/Var)
        //   q2 = If/Ikf + Ir/Ikr
        //   qb = (q1/2) * (1 + sqrt(1 + 4*q2))
        //
        // Derivative derivation via chain rule:
        //   d(q1)/d(vbe) = q1^2 / Var  (since d(1/x)/dx = -1/x^2 and sign flip)
        //   d(q1)/d(vbc) = q1^2 / Vaf
        //
        // Let s = sqrt(1 + 4*q2), then:
        //   d(qb)/d(vbe) = (d(q1)/d(vbe)) * (1+s)/2
        //                  + q1/2 * 2/(s) * d(q2)/d(vbe)
        //                = q1^2/Var * (1+s)/2  +  q1/s * (g_f/Ikf)
        //
        //   d(qb)/d(vbc) = q1^2/Vaf * (1+s)/2  +  q1/s * (g_r/Ikr)
        let inv_vaf = 1.0 / vaf;
        let inv_var = 1.0 / var;
        let inv_ikf = 1.0 / ikf;
        let inv_ikr = 1.0 / ikr;
        let inv_bf = 1.0 / bf;
        let inv_br = 1.0 / br;

        let q1_denom = 1.0 - vbc * inv_vaf - vbe * inv_var;
        // Guard against degenerate q1 (only in extreme saturation, not normally reached).
        let q1 = 1.0 / q1_denom.max(1e-10);

        let q2 = i_f * inv_ikf + i_r * inv_ikr;
        let arg = (1.0 + 4.0 * q2).max(0.0);
        let sqarg = arg.sqrt();
        let qb = q1 * (1.0 + sqarg) * 0.5;
        let inv_qb = 1.0 / qb.max(1e-30);
        let inv_sqarg = if sqarg > 1e-30 { 1.0 / sqarg } else { 0.0 };

        // d(qb)/d(vbe):
        //   from q1 term:  q1^2 * inv_var * (1 + sqarg) * 0.5
        //   from sqarg term: q1 * 0.5 * (2/sqarg) * dq2/d(vbe) = q1 * g_f * inv_ikf * inv_sqarg
        let dqb_dvbe = q1 * q1 * inv_var * (1.0 + sqarg) * 0.5 + q1 * g_f * inv_ikf * inv_sqarg;

        // d(qb)/d(vbc):
        let dqb_dvbc = q1 * q1 * inv_vaf * (1.0 + sqarg) * 0.5 + q1 * g_r * inv_ikr * inv_sqarg;

        // ── Transport current and its Jacobian contributions ──────────────────
        //
        //   Icc = (If - Ir) / qb
        //
        // d(Icc)/d(vbe) = g_f/qb - (If - Ir)/qb^2 * dqb_dvbe
        //               = g_f * inv_qb - Icc * inv_qb * dqb_dvbe
        //
        // d(Icc)/d(vbc) = -g_r * inv_qb - Icc * inv_qb * dqb_dvbc
        let icc = (i_f - i_r) * inv_qb;
        let dicc_dvbe = g_f * inv_qb - icc * inv_qb * dqb_dvbe;
        let dicc_dvbc = -g_r * inv_qb - icc * inv_qb * dqb_dvbc;

        // ── Terminal base currents ────────────────────────────────────────────
        //   Ibe = If/Bf + Ibe_rec    (into base at BE junction)
        //   Ibc = Ir/Br + Ibc_rec    (into base at BC junction)
        let ibe = i_f * inv_bf + ibe_rec;
        let ibc = i_r * inv_br + ibc_rec;

        let dibe_dvbe = g_f * inv_bf + gbe_rec;
        let dibc_dvbc = g_r * inv_br + gbc_rec;
        // Cross terms: ibe does not depend on vbc; ibc does not depend on vbe.

        // ── Intrinsic terminal currents ───────────────────────────────────────
        //   Ic = Icc - Ibc
        //   Ib = Ibe + Ibc
        //   Ie = -(Icc + Ibe)
        let ic_intrinsic = icc - ibc;
        let ib_intrinsic = ibe + ibc;
        let ie_intrinsic = -(icc + ibe);

        // Jacobian of intrinsic currents w.r.t. (vbe, vbc):
        let dic_dvbe = dicc_dvbe; // d(Icc)/d(vbe); Ibc no vbe dep
        let dic_dvbc = dicc_dvbc - dibc_dvbc; // d(Icc-Ibc)/d(vbc)
        let dib_dvbe = dibe_dvbe; // d(Ibe)/d(vbe); Ibc no vbe dep
        let dib_dvbc = dibc_dvbc; // d(Ibc)/d(vbc); Ibe no vbc dep
        let die_dvbe = -(dicc_dvbe + dibe_dvbe);
        let die_dvbc = -dicc_dvbc; // Ibe no vbc dep

        // ── GMIN leakage across junctions (numerical stability) ───────────────
        let gmin = Self::GMIN;
        // Small conductance between B-C and B-E to keep Jacobian non-singular.
        let ic_gmin = gmin * (vc - vb); // leakage into collector
        let ib_gmin = gmin * (vb - vc) + gmin * (vb - ve);
        let ie_gmin = gmin * (ve - vb);

        // Apply polarity: terminal current = p * intrinsic + gmin_leak
        let ic = p * ic_intrinsic + ic_gmin;
        let ib = p * ib_intrinsic + ib_gmin;
        let ie = p * ie_intrinsic + ie_gmin;

        // ── Jacobian: chain rule from (vbe,vbc) to (Vc,Vb,Ve) ────────────────
        //
        //   vbe = p*(Vb - Ve)  →  d/dVc = 0,    d/dVb = p,   d/dVe = -p
        //   vbc = p*(Vb - Vc)  →  d/dVc = -p,   d/dVb = p,   d/dVe = 0
        //
        //   d(terminal_i)/d(Vj) = p * [d(intrinsic_i)/d(vbe)*d(vbe)/d(Vj)
        //                              + d(intrinsic_i)/d(vbc)*d(vbc)/d(Vj)]
        //
        // Since p^2 = 1:
        //   d(Ic)/d(Vc) = p * [dic_dvbc * (-p)] = -dic_dvbc
        //   d(Ic)/d(Vb) = p * [dic_dvbe * p  +  dic_dvbc * p] = dic_dvbe + dic_dvbc
        //   d(Ic)/d(Ve) = p * [dic_dvbe * (-p)] = -dic_dvbe
        let dic_dvc = -dic_dvbc;
        let dic_dvb = dic_dvbe + dic_dvbc;
        let dic_dve = -dic_dvbe;

        let dib_dvc = -dib_dvbc;
        let dib_dvb = dib_dvbe + dib_dvbc;
        let dib_dve = -dib_dvbe;

        let die_dvc = -die_dvbc;
        let die_dvb = die_dvbe + die_dvbc;
        let die_dve = -die_dvbe;

        // ── Transit-time forward charge Q_F = TF_eff * If ────────────────────
        //
        // ngspice Gummel-Poon transit-time modulation (bjtload.c:652-674):
        //
        //   ovtf = 1 / (1.44 * VTF)
        //   itf_ratio = (If / (If + ITF))^2    [If = forward diode current]
        //   argtf = XTF * itf_ratio * exp(Vbc * ovtf)
        //   TF_eff = TF * (1 + argtf)
        //
        // Diffusion charge:  Q_F = TF_eff * If
        //
        // Derivatives (for C Jacobian):
        //   dQ_F/dVbe = TF_eff * g_f + If * dTF_eff/dVbe
        //     where dTF_eff/dVbe = TF * XTF * exp(Vbc*ovtf) * d(itf_ratio)/d(If) * g_f
        //   dQ_F/dVbc = If * dTF_eff/dVbc     [If has no Vbc dependence]
        //     where dTF_eff/dVbc = TF * XTF * itf_ratio * exp(Vbc*ovtf) * ovtf
        //
        // PTF is excess phase in degrees, applied as cos(ptf_rad) scale.
        //
        // Pin conventions: Q_F charges the base (pin 1) and discharges at the
        // emitter — net effect is +Q_F on base, -Q_F on emitter.
        let (q_tf, c_tf_be, c_tf_bc) = if tf > 0.0 && i_f > 0.0 {
            // ITF ratio: (If / (If + ITF))^2
            let (itf_sq, ditf_sq_dif) = if itf > 0.0 {
                let denom = i_f + itf;
                let ratio = i_f / denom;
                // d(ratio^2)/d(If) = 2 * ratio * d(ratio)/d(If)
                //                   = 2 * (If/denom) * (itf/denom^2)
                //                   = 2 * If * itf / denom^3
                let slope = 2.0 * i_f * itf / denom.powi(3);
                (ratio * ratio, slope)
            } else {
                (1.0, 0.0)
            };

            // VBC exponential: exp(Vbc / (1.44 * VTF))
            let ovtf = 1.0 / (1.44 * vtf);
            let vbc_exp = if vtf < 1e29 {
                (vbc * ovtf).clamp(-80.0, 80.0).exp()
            } else {
                1.0
            };

            let argtf = if xtf != 0.0 {
                xtf * itf_sq * vbc_exp
            } else {
                0.0
            };
            let tf_eff = tf * (1.0 + argtf);

            // PTF (excess phase) scales the transit-time charge by cos(ptf_rad).
            // PTF is specified in degrees at frequency 1/(2*pi*TF); in the real-valued
            // transient/DC stamp the imaginary (sin) component is not representable,
            // so we scale the stored charge by cos(ptf_rad) — the standard SPICE
            // approximation for the effect of excess phase on minority-carrier storage.
            let ptf_scale = if ptf != 0.0 {
                let ptf_rad = ptf * std::f64::consts::PI / 180.0;
                ptf_rad.cos()
            } else {
                1.0
            };

            // Diffusion charge: Q_F = TF_eff * If (ngspice: Qbe_diff = tf_eff * cbe)
            let q_f = tf_eff * i_f * ptf_scale;

            // dTF_eff/dVbe: chain through If via ITF ratio only (Vbc exp is const w.r.t. Vbe)
            //   = TF * XTF * vbc_exp * d(itf_sq)/d(If) * g_f
            let dtf_dvbe = if xtf != 0.0 {
                tf * xtf * vbc_exp * ditf_sq_dif * g_f
            } else {
                0.0
            };

            // dTF_eff/dVbc: only from the exp(Vbc*ovtf) term (If and itf_sq are const w.r.t. Vbc)
            //   = TF * XTF * itf_sq * exp(Vbc*ovtf) * ovtf
            let dtf_dvbc = if xtf != 0.0 && vtf < 1e29 {
                tf * xtf * itf_sq * vbc_exp * ovtf
            } else {
                0.0
            };

            // dQ_F/dVbe = TF_eff * g_f + If * dTF_eff/dVbe, scaled by PTF.
            // dQ_F/dVbc = If * dTF_eff/dVbc  (If has no Vbc dep), scaled by PTF.
            let dqf_dvbe = ptf_scale * (tf_eff * g_f + i_f * dtf_dvbe);
            let dqf_dvbc = ptf_scale * (i_f * dtf_dvbc);

            (q_f, dqf_dvbe, dqf_dvbc)
        } else {
            (0.0, 0.0, 0.0)
        };

        // Chain rule (vbe, vbc) → (Vc, Vb, Ve) for charge Jacobian (same as G above).
        // dQ/dVc = -dQ/dVbc
        // dQ/dVb =  dQ/dVbe + dQ/dVbc
        // dQ/dVe = -dQ/dVbe
        let dqf_dvc = -c_tf_bc;
        let dqf_dvb = c_tf_be + c_tf_bc;
        let dqf_dve = -c_tf_be;

        // ── Transit-time reverse charge Q_R = TR * Ir ────────────────────────
        //
        // The reverse transit time TR stores minority-carrier charge at the BC
        // junction during reverse/saturation operation.  By analogy with Q_F:
        //
        //   Q_R = TR * Ir   (Ir = reverse transport current through BC junction)
        //
        // Q_R is stored on the base (+) and removed from the collector (−):
        //   q[1] += +Q_R  (base)
        //   q[0] += -Q_R  (collector)
        //
        // Jacobian:
        //   dQ_R/dVbc = TR * g_r  →  chain-rule to Vc/Vb below.
        //   dQ_R/dVbe = 0         (Ir does not depend on Vbe in GP model)
        let (q_tr, dqr_dvc, dqr_dvb) = if tr > 0.0 {
            let q_r = tr * i_r;
            // dVbc/dVb = p, dVbc/dVc = -p; p^2 = 1
            let dqr_dvbc = tr * g_r;
            let dqr_dvc_local = -dqr_dvbc; // d(Q_R)/d(Vc) = dQ_R/dVbc * d(Vbc)/d(Vc) = dqr_dvbc * (-p)*p = -dqr_dvbc
            let dqr_dvb_local = dqr_dvbc; // d(Q_R)/d(Vb) = dqr_dvbc * p*p = +dqr_dvbc
            (q_r, dqr_dvc_local, dqr_dvb_local)
        } else {
            (0.0, 0.0, 0.0)
        };

        // ── CJE / CJC — base-emitter and base-collector depletion capacitance ──
        //
        // Standard SPICE junction charge formula (same as CJS above):
        //   For V < FC*VJ:   C = CJ * (1 - V/VJ)^(-MJ)
        //                    Q = CJ*VJ/(1-MJ) * [1 - (1 - V/VJ)^(1-MJ)]
        //   For V >= FC*VJ:  C = CJ * (1-FC)^(-(1+MJ)) * [1 - FC*(1+MJ) + MJ*V/VJ]
        //                    Q = Q_knee + C_knee * (V - FC*VJ)
        //                        where C_knee = CJ / (1-FC)^MJ
        //
        // CJE is referenced Vbe (base-emitter junction):
        //   +Q_be_dep on base (pin 1), -Q_be_dep on emitter (pin 2).
        // CJC is referenced Vbc (base-collector junction):
        //   +Q_bc_dep on base (pin 1), -Q_bc_dep on collector (pin 0).

        /// Compute (charge, capacitance) for a SPICE depletion junction.
        #[inline(always)]
        fn junction_qc(v: f64, cj: f64, vj: f64, mj: f64, fc: f64) -> (f64, f64) {
            let fc_vj = fc * vj;
            if v < fc_vj {
                let denom = (1.0 - v / vj).max(1e-6);
                let cap = cj * denom.powf(-mj);
                let charge = if (mj - 1.0).abs() > 1e-6 {
                    cj * vj / (1.0 - mj) * (1.0 - denom.powf(1.0 - mj))
                } else {
                    -cj * vj * denom.ln()
                };
                (charge, cap)
            } else {
                let denom0 = (1.0 - fc).max(1e-6);
                let q_knee = if (mj - 1.0).abs() > 1e-6 {
                    cj * vj / (1.0 - mj) * (1.0 - denom0.powf(1.0 - mj))
                } else {
                    -cj * vj * denom0.ln()
                };
                let cap_knee = cj / denom0.powf(mj);
                let cap = cj / denom0.powf(1.0 + mj) * (1.0 - fc * (1.0 + mj) + mj * v / vj);
                let charge = q_knee + cap_knee * (v - fc_vj);
                (charge, cap)
            }
        }

        // CJE: junction voltage is Vbe (already polarity-adjusted).
        let (q_cje, c_be_dep) = if cje > 0.0 {
            junction_qc(vbe, cje, vje, mje, fc)
        } else {
            (0.0, 0.0)
        };

        // CJC: junction voltage is Vbc (already polarity-adjusted).
        //
        // XCJC splits the BC depletion cap between the internal base node (xcjc
        // fraction, when internal nodes exist) and the external base node
        // ((1-xcjc) fraction, always present).  In the 3-terminal eval both
        // fractions land on pin 1 (external base), so the total is still q_cjc.
        // The xcjc split only matters in eval_with_extrinsic (6-terminal path)
        // where pin 1 = external base and pin 4 = internal base; that function
        // uses these values directly.  Store both split charges here.
        let (q_cjc, c_bc_dep) = if cjc > 0.0 {
            junction_qc(vbc, cjc, vjc, mjc, fc)
        } else {
            (0.0, 0.0)
        };
        // XCJC split is handled by the caller (eval_gp or eval_with_extrinsic).
        // c_bc_dep and q_cjc are returned separately from this function.

        // ── CJS — collector-substrate junction capacitance ────────────────────
        //
        // CJS is the collector-to-substrate depletion capacitance. In the standard
        // 3-terminal GP BJT model (no explicit substrate pin) it is connected between
        // the collector node (pin 0) and ground, matching ngspice's treatment when
        // the substrate node is absent.
        //
        // Cj_cs(Vc) = CJS / (1 - Vc/VJS)^MJS   for Vc < FC*VJS
        //           = CJS / (1 - FC)^(1+MJS) * (1 - MJS*(Vc - FC*VJS) / (VJS*(1-FC)))
        //                                          for Vc >= FC*VJS
        //
        // Charge:  Q_cs = integral of Cj_cs dVc  (used for transient q[] vector)
        // Here we stamp Vc referenced to ground, so positive charge is on pin 0.
        let (q_cjs, c_cjs) = if cjs > 0.0 {
            // Use the same junction_cap/charge helpers as diode if available;
            // since we're in bjt.rs we inline the formulas directly.
            let vc_col = vc; // collector voltage (pin 0)
            let fc_vjs = fc * vjs;
            let (cap, charge) = if vc_col < fc_vjs {
                let denom = 1.0 - vc_col / vjs;
                let denom_clamped = denom.max(1e-6);
                let cap = cjs / denom_clamped.powf(mjs);
                // Q = CJS*VJS/(1-MJS) * (1 - (1 - Vc/VJS)^(1-MJS))  for MJS != 1
                let charge = if (mjs - 1.0).abs() > 1e-6 {
                    cjs * vjs / (1.0 - mjs) * (1.0 - denom_clamped.powf(1.0 - mjs))
                } else {
                    -cjs * vjs * denom_clamped.ln()
                };
                (cap, charge)
            } else {
                // Linearisation past FC*VJS (SPICE standard).
                let f1 = (1.0 - fc).powf(1.0 + mjs);
                let cap = cjs / f1 * (1.0 - mjs * (vc_col - fc_vjs) / (vjs * (1.0 - fc)));
                // Charge: integrate from 0 to FC*VJS using exact formula, then linear.
                let denom0 = 1.0 - fc;
                let q_knee = if (mjs - 1.0).abs() > 1e-6 {
                    cjs * vjs / (1.0 - mjs) * (1.0 - denom0.powf(1.0 - mjs))
                } else {
                    -cjs * vjs * denom0.ln()
                };
                // Linear extension: Q_knee + cap_at_knee * (Vc - fc*VJS)
                //   where cap_at_knee = cjs / (1-fc)^mjs
                let cap_knee = cjs / (1.0 - fc).powf(mjs);
                let charge = q_knee + cap_knee * (vc_col - fc_vjs);
                (cap, charge)
            };
            (charge, cap)
        } else {
            (0.0, 0.0)
        };

        // ── Assemble DeviceEval ───────────────────────────────────────────────
        // GMIN contributions to the Jacobian diagonal (d(gmin_leak)/d(V)):
        //   d(ic_gmin)/dVc = +gmin,  d(ic_gmin)/dVb = -gmin
        //   d(ib_gmin)/dVb = +2*gmin, d(ib_gmin)/dVc = -gmin, d(ib_gmin)/dVe = -gmin
        //   d(ie_gmin)/dVe = +gmin,  d(ie_gmin)/dVb = -gmin
        //
        // Transit-time charge Q_F: net charge flows base (+) and emitter (-).
        // CJS charge Q_cs: referenced collector-to-ground (pin 0 relative to ground).

        // Build C Jacobian entries (accumulate tf, tr, cje, cjc, and cjs contributions).
        let mut cap_entries: SmallVec<[(u8, u8, f64); 16]> = SmallVec::new();
        if q_tf != 0.0 || dqf_dvb != 0.0 || dqf_dvc != 0.0 || dqf_dve != 0.0 {
            // Q_F on base (pin 1) and -Q_F on emitter (pin 2).
            // C[row][col] = dQ_row/dV_col.
            //
            // q[base] = p * q_tf, so d(q[base])/dVb = p * dqf_dvb.
            // The dqf_dv{b,c,e} derivatives already had one factor of p
            // cancelled via p^2=1 in the (vbe,vbc)→(Vc,Vb,Ve) chain rule,
            // but q[] carries an explicit p, so we must multiply C entries
            // by p to keep C consistent with q.  For NPN (p=1) this is a
            // no-op; for PNP (p=-1) it corrects the sign.
            if dqf_dvb != 0.0 {
                cap_entries.push((1, 1, p * dqf_dvb));
            }
            if dqf_dvc != 0.0 {
                cap_entries.push((1, 0, p * dqf_dvc));
            }
            if dqf_dve != 0.0 {
                cap_entries.push((1, 2, p * dqf_dve));
            }
            // Emitter row: -Q_F so signs flip.
            if dqf_dvb != 0.0 {
                cap_entries.push((2, 1, -p * dqf_dvb));
            }
            if dqf_dvc != 0.0 {
                cap_entries.push((2, 0, -p * dqf_dvc));
            }
            if dqf_dve != 0.0 {
                cap_entries.push((2, 2, -p * dqf_dve));
            }
        }
        // Q_R (TR reverse transit charge) on base (+) and collector (−).
        // dQ_R/dVc and dQ_R/dVb are non-zero; dQ_R/dVe = 0 (Ir has no Vbe dep).
        // Same polarity reasoning as Q_F above: multiply by p.
        if q_tr != 0.0 || dqr_dvc != 0.0 || dqr_dvb != 0.0 {
            if dqr_dvb != 0.0 {
                cap_entries.push((1, 1, p * dqr_dvb));
            } // dQ_base/dVb
            if dqr_dvc != 0.0 {
                cap_entries.push((1, 0, p * dqr_dvc));
            } // dQ_base/dVc
            if dqr_dvb != 0.0 {
                cap_entries.push((0, 1, -p * dqr_dvb));
            } // dQ_collector/dVb
            if dqr_dvc != 0.0 {
                cap_entries.push((0, 0, -p * dqr_dvc));
            } // dQ_collector/dVc
        }
        if c_be_dep != 0.0 {
            // CJE across Vbe: +Q on base (pin 1), -Q on emitter (pin 2).
            // dVbe/dVb = p, dVbe/dVe = -p; p^2 = 1 so factors collapse as in G chain rule.
            cap_entries.push((1, 1, c_be_dep)); // dQ_base/dVb
            cap_entries.push((1, 2, -c_be_dep)); // dQ_base/dVe
            cap_entries.push((2, 1, -c_be_dep)); // dQ_emitter/dVb
            cap_entries.push((2, 2, c_be_dep)); // dQ_emitter/dVe
        }
        // CJC entries are NOT stamped here — they are returned separately so that
        // eval_with_extrinsic can apply the XCJC split correctly (Fix 4.1).
        // In the 3-pin wrapper (eval_gp), the caller adds CJC to cap_entries.
        if c_cjs != 0.0 {
            // CJS between collector (pin 0) and ground:
            // q[0] = p * q_cjs, and q_cjs uses physical Vc (no junction transform),
            // so d(q[0])/dVc = p * c_cjs.  For NPN (p=1) this is just c_cjs.
            cap_entries.push((0, 0, p * c_cjs));
        }

        // q[] excludes CJC charge — caller adds it to the appropriate pins.
        let eval = DeviceEval {
            g: smallvec![ic, ib, ie],
            q: smallvec![
                p * (-q_tr + q_cjs),       // collector: −Q_R + Q_cs(cjs) [CJC excluded]
                p * (q_tf + q_tr + q_cje), // base: +Q_F + Q_R + Q_be_dep(cje) [CJC excluded]
                p * (-q_tf - q_cje),       // emitter: −Q_F − Q_be_dep(cje)
            ],
            G: smallvec![
                // Collector row (pin 0)
                (0, 0, dic_dvc + gmin),
                (0, 1, dic_dvb - gmin),
                (0, 2, dic_dve),
                // Base row (pin 1)
                (1, 0, dib_dvc - gmin),
                (1, 1, dib_dvb + 2.0 * gmin),
                (1, 2, dib_dve - gmin),
                // Emitter row (pin 2)
                (2, 0, die_dvc),
                (2, 1, die_dvb - gmin),
                (2, 2, die_dve + gmin),
            ],
            C: cap_entries,
            rhs: SmallVec::new(),
        };
        (eval, c_bc_dep, q_cjc)
    }

    /// Full Gummel-Poon evaluation (level=1) — 3-pin wrapper.
    ///
    /// Calls [`eval_gp_core`] and folds CJC entries (unsplit) into the returned
    /// `DeviceEval`, which is appropriate for the 3-terminal path where no
    /// internal/external base distinction exists.
    fn eval_gp(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let (mut eval, c_bc_dep, q_cjc) = self.eval_gp_core(voltages, params);
        let p = self.polarity;

        // Add CJC charge to q[].
        eval.q[0] += p * (-q_cjc); // collector: −Q_bc_dep
        eval.q[1] += p * q_cjc;    // base: +Q_bc_dep

        // Stamp full CJC capacitance at pins 0 (collector) and 1 (base).
        if c_bc_dep != 0.0 {
            eval.C.push((1, 1, c_bc_dep));   // dQ_base/dVb
            eval.C.push((1, 0, -c_bc_dep));  // dQ_base/dVc
            eval.C.push((0, 1, -c_bc_dep));  // dQ_collector/dVb
            eval.C.push((0, 0, c_bc_dep));   // dQ_collector/dVc
        }

        eval
    }
}

impl DeviceModel for Bjt {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let rb = params.get_or("rb", 0.0);
        let re = params.get_or("re", 0.0);
        let rc = params.get_or("rc", 0.0);
        if rb > 0.0 || re > 0.0 || rc > 0.0 {
            return self.eval_with_extrinsic(voltages, params, rb, re, rc);
        }
        self.eval_intrinsic_3pin(voltages, params)
    }

    fn num_terminals(&self) -> usize {
        3
    }

    fn kind(&self) -> DeviceKind {
        if self.polarity > 0.0 {
            DeviceKind::BjtNpn
        } else {
            DeviceKind::BjtPnp
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Basic NPN parameters (no Early/high-injection effects, pure Ebers-Moll-like).
    fn npn_params() -> ParamMap {
        let mut p = ParamMap::new();
        p.set("is", 1e-16);
        p.set("bf", 100.0);
        p.set("nf", 1.0);
        p.set("br", 1.0);
        p.set("nr", 1.0);
        p.set("vt", 0.02585);
        p
    }

    // ── Helper: centered finite-difference check of full 3x3 Jacobian ────────
    /// Returns max relative error across all 9 Jacobian entries at voltage `v`.
    /// Uses centered differences for better accuracy near nonlinear operating
    /// points (high-injection, saturation).
    fn jacobian_max_rel_err(bjt: &Bjt, v: &[f64; 3], params: &ParamMap) -> f64 {
        let h = 1e-5_f64;
        let e0 = bjt.eval(v, params);
        let mut max_err = 0.0_f64;
        for col in 0u8..3 {
            let mut vp = *v;
            let mut vm = *v;
            vp[col as usize] += h;
            vm[col as usize] -= h;
            let ep = bjt.eval(&vp, params);
            let em = bjt.eval(&vm, params);
            for row in 0u8..3 {
                let fd = (ep.g[row as usize] - em.g[row as usize]) / (2.0 * h);
                let analytic =
                    e0.G.iter()
                        .find(|(r, c, _)| *r == row && *c == col)
                        .map(|(_, _, val)| *val)
                        .unwrap_or(0.0);
                let scale = analytic.abs().max(fd.abs()).max(1e-20);
                let rel = (fd - analytic).abs() / scale;
                if rel > max_err {
                    max_err = rel;
                }
            }
        }
        max_err
    }

    fn cap_entry_sum(eval: &DeviceEval, row: u8, col: u8) -> f64 {
        eval.C
            .iter()
            .filter(|(r, c, _)| *r == row && *c == col)
            .map(|(_, _, val)| *val)
            .sum()
    }

    // ── Existing tests (must remain passing) ─────────────────────────────────

    #[test]
    fn bjt_npn_forward_active() {
        // Vc=5, Vb=0.7, Ve=0 → forward active.
        let q = Bjt::npn();
        let params = npn_params();
        let eval = q.eval(&[5.0, 0.7, 0.0], &params);

        // Ic > 0 (into collector for NPN).
        assert!(eval.g[0] > 0.0, "Ic should be > 0, got {}", eval.g[0]);
        // Ib > 0, ≈ Ic / βF.
        assert!(eval.g[1] > 0.0, "Ib should be > 0, got {}", eval.g[1]);
        // Ie < 0 (out of emitter).
        assert!(eval.g[2] < 0.0, "Ie should be < 0, got {}", eval.g[2]);

        // KCL: Ic + Ib + Ie ≈ 0.
        let kcl = eval.g[0] + eval.g[1] + eval.g[2];
        assert!(kcl.abs() < 1e-6, "KCL violated: {}", kcl);

        // β_eff ≈ 100 in forward active (loose tolerance for GMIN).
        let beta_eff = eval.g[0] / eval.g[1];
        assert!((beta_eff - 100.0).abs() < 5.0, "beta_eff={}", beta_eff);
    }

    #[test]
    fn bjt_npn_cutoff() {
        // Vbe = Vbc = 0 → no injection, only GMIN leakage.
        let q = Bjt::npn();
        let params = npn_params();
        let eval = q.eval(&[0.0, 0.0, 0.0], &params);
        assert!(eval.g[0].abs() < 1e-10);
        assert!(eval.g[1].abs() < 1e-10);
        assert!(eval.g[2].abs() < 1e-10);
    }

    #[test]
    fn bjt_pnp_forward_active() {
        // PNP forward active: Ve=5, Vb=4.3, Vc=0.
        let q = Bjt::pnp();
        let params = npn_params();
        let eval = q.eval(&[0.0, 4.3, 5.0], &params);

        // Conventional current flows E→C: Ic < 0, Ie > 0, Ib < 0.
        assert!(eval.g[0] < 0.0, "PNP Ic should be < 0, got {}", eval.g[0]);
        assert!(eval.g[1] < 0.0, "PNP Ib should be < 0, got {}", eval.g[1]);
        assert!(eval.g[2] > 0.0, "PNP Ie should be > 0, got {}", eval.g[2]);

        // KCL.
        let kcl = eval.g[0] + eval.g[1] + eval.g[2];
        assert!(kcl.abs() < 1e-6);
    }

    #[test]
    fn bjt_polarity_flag() {
        assert_eq!(Bjt::npn().kind(), DeviceKind::BjtNpn);
        assert_eq!(Bjt::pnp().kind(), DeviceKind::BjtPnp);
    }

    #[test]
    fn bjt_overflow_protection() {
        // Insanely high Vbe — must produce finite currents.
        let q = Bjt::npn();
        let params = npn_params();
        let eval = q.eval(&[5.0, 5.0, 0.0], &params);
        assert!(eval.g[0].is_finite(), "Ic not finite: {}", eval.g[0]);
        assert!(eval.g[1].is_finite(), "Ib not finite: {}", eval.g[1]);
        assert!(eval.g[2].is_finite(), "Ie not finite: {}", eval.g[2]);
    }

    #[test]
    fn bjt_jacobian_finite_difference() {
        // NPN at moderate Vb: analytic Jacobian vs. forward FD.
        let q = Bjt::npn();
        let params = npn_params();
        let v = [3.0, 0.7, 0.0];
        let h = 1e-6;
        let e0 = q.eval(&v, &params);
        let ep = q.eval(&[v[0], v[1] + h, v[2]], &params);
        let fd = (ep.g[0] - e0.g[0]) / h;
        let analytic =
            e0.G.iter()
                .find(|(r, c, _)| *r == 0 && *c == 1)
                .map(|(_, _, v)| *v)
                .unwrap();
        assert!(
            (fd - analytic).abs() / analytic.abs().max(1e-20) < 1e-2,
            "NPN FD d(Ic)/d(Vb): fd={} analytic={}",
            fd,
            analytic
        );
    }

    // ── New required tests (§2.4) ─────────────────────────────────────────────

    /// Saturation region: both junctions forward biased.
    /// Vbe ≈ 0.7 V (forward), Vbc ≈ 0.5 V (also forward, so device is saturated).
    /// In saturation: Ic << Bf*Ib (Ic/Ib << Bf), and Ic is still positive but
    /// reduced by the reverse transport component.
    #[test]
    fn bjt_npn_saturation() {
        let q = Bjt::npn();
        let params = npn_params();
        // Vc=0.2, Vb=0.7, Ve=0 → Vbe=0.7 V forward, Vbc=0.5 V forward → saturation.
        let eval = q.eval(&[0.2, 0.7, 0.0], &params);

        let ic = eval.g[0];
        let ib = eval.g[1];
        let ie = eval.g[2];

        // In saturation Ic > 0 but reduced; Ib > 0; Ie < 0.
        assert!(ic > 0.0, "sat: Ic should be > 0, got {ic}");
        assert!(ib > 0.0, "sat: Ib should be > 0, got {ib}");
        assert!(ie < 0.0, "sat: Ie should be < 0, got {ie}");

        // KCL.
        let kcl = ic + ib + ie;
        assert!(kcl.abs() < 1e-6, "sat: KCL violated: {kcl}");

        // β_eff in saturation is < Bf (collector current is suppressed).
        let beta_eff = ic / ib;
        assert!(
            beta_eff < 100.0,
            "sat: beta_eff={beta_eff} should be < Bf=100 (saturation)"
        );

        // Jacobian FD check in saturation.
        let max_err = jacobian_max_rel_err(&q, &[0.2, 0.7, 0.0], &params);
        assert!(max_err < 5e-2, "sat Jacobian FD error: {max_err}");
    }

    /// Reverse-active region: Vbc forward-biased, Vbe reverse-biased.
    /// Roles of emitter and collector are swapped. For NPN with Br=1:
    ///   Ib = If/Bf + Ir/Br  — If≈0 (Vbe reverse), Ir/Br > 0 (Vbc forward)
    ///   so Ib > 0 (base sources current into the reverse-biased junction).
    ///
    ///   Transport current Icc = (If - Ir)/qb < 0 (Ir dominates).
    ///   Ic = Icc - Ibc < 0 (current out of collector).
    ///   Ie = -(Icc + Ibe) > 0 (current into emitter).
    ///
    /// β_r_eff = |Ic| / Ib ≈ Br = 1.
    #[test]
    fn bjt_npn_reverse_active() {
        let q = Bjt::npn();
        let params = npn_params();
        // Vc=0, Vb=0.7, Ve=1.2 → Vbe=0.7-1.2=-0.5 V (reverse), Vbc=0.7-0=0.7 V (forward)
        let eval = q.eval(&[0.0, 0.7, 1.2], &params);

        let ic = eval.g[0];
        let ib = eval.g[1];
        let ie = eval.g[2];

        // Ic < 0 (reverse transport dominates, current flows out of collector).
        assert!(ic < 0.0, "rev-active: Ic should be < 0, got {ic}");
        // Ie > 0 (emitter receives current in reverse-active).
        assert!(ie > 0.0, "rev-active: Ie should be > 0, got {ie}");
        // With Br=1, base current is positive (Ir/Br flows into base).
        assert!(ib > 0.0, "rev-active: Ib should be > 0 for Br=1, got {ib}");

        // KCL.
        let kcl = ic + ib + ie;
        assert!(kcl.abs() < 1e-6, "rev-active: KCL violated: {kcl}");

        // In reverse-active Ic is negative and dominated by the reverse transport.
        // |Ic| should be much larger than GMIN-level leakage — check we are truly
        // in injection-dominated reverse-active (not just leakage).
        assert!(
            ic.abs() > 1e-6,
            "rev-active: |Ic|={} should be injection-level, not leakage",
            ic.abs()
        );

        // In GP reverse-active: Ic = Icc - Ibc = -Ir/qb - Ir/Br
        // Ib = If/Bf + Ir/Br ≈ Ir/Br
        // So |Ic|/Ib = (1/qb + 1/Br) / (1/Br) = Br/qb + 1
        // With Br=1, qb≈1: beta_r_eff ≈ 1 + 1 = 2.
        // This is the correct GP result — more current out of collector than
        // into base because Icc carries the same Ir that Ibc also carries.
        let beta_r_eff = ic.abs() / ib;
        assert!(
            (beta_r_eff - 2.0).abs() < 0.5,
            "rev-active: beta_r_eff={beta_r_eff:.3} should be ≈ 2 for Br=1 in GP model"
        );

        // Jacobian FD check.
        let max_err = jacobian_max_rel_err(&q, &[0.0, 0.7, 1.2], &params);
        assert!(max_err < 5e-2, "rev-active Jacobian FD error: {max_err}");
    }

    /// Early effect: with Vaf=50, Ic should increase ~linearly as Vc sweeps 1..5 V.
    /// The slope should be ≈ Ic(Vc=3) / Vaf (output conductance go = Ic/Vaf).
    #[test]
    fn bjt_early_effect() {
        let q = Bjt::npn();
        let mut p = npn_params();
        p.set("vaf", 50.0);

        // Fixed Vb=0.7, Ve=0; sweep Vc 1..5 V.
        let ic: Vec<f64> = (1..=5)
            .map(|vc| q.eval(&[vc as f64, 0.7, 0.0], &p).g[0])
            .collect();

        // Ic must strictly increase with Vc (forward Early effect).
        for w in ic.windows(2) {
            assert!(w[1] > w[0], "Ic should increase with Vc: {:?}", ic);
        }

        // Numerical go at Vc=3 from the Jacobian should match Ic/Vaf approximately.
        let eval_mid = q.eval(&[3.0, 0.7, 0.0], &p);
        let go_analytic = eval_mid
            .G
            .iter()
            .find(|(r, c, _)| *r == 0 && *c == 0)
            .map(|(_, _, v)| *v)
            .unwrap_or(0.0);

        let ic_mid = eval_mid.g[0];
        let go_expected = ic_mid / 50.0; // ≈ Ic / Vaf
        // Allow factor-of-3 tolerance (qb makes it slightly different from raw Ic/Vaf).
        assert!(
            (go_analytic - go_expected).abs() / go_expected.abs().max(1e-30) < 3.0,
            "go_analytic={} go_expected={} Ic_mid={}",
            go_analytic,
            go_expected,
            ic_mid
        );

        // FD Jacobian check at Vc=3.
        let max_err = jacobian_max_rel_err(&q, &[3.0, 0.7, 0.0], &p);
        assert!(max_err < 5e-2, "Early-effect Jacobian FD error: {max_err}");
    }

    /// High-injection rolloff: at Vbe=0.85 with Ikf=1e-3, β_eff should be < Bf.
    #[test]
    fn bjt_high_injection() {
        let q = Bjt::npn();
        let mut p = npn_params();
        p.set("ikf", 1e-3); // low knee so high-injection kicks in at moderate Ic

        let eval = q.eval(&[5.0, 0.85, 0.0], &p);
        let ic = eval.g[0];
        let ib = eval.g[1];
        assert!(ic > 0.0 && ib > 0.0, "should be forward active");

        let beta_eff = ic / ib;
        // High-injection reduces β below the nominal Bf=100.
        assert!(
            beta_eff < 100.0,
            "high-injection should reduce beta: beta_eff={:.2}",
            beta_eff
        );

        // FD Jacobian check.
        let max_err = jacobian_max_rel_err(&q, &[5.0, 0.85, 0.0], &p);
        assert!(
            max_err < 5e-2,
            "high-injection Jacobian FD error: {max_err}"
        );
    }

    /// Recombination current: with Ise=1e-13, Ne=2 at low Vbe=0.5,
    /// the base current is dominated by recombination so Ic/Ib < Bf.
    #[test]
    fn bjt_recombination() {
        let q = Bjt::npn();
        let mut p = npn_params();
        p.set("ise", 1e-13);
        p.set("ne", 2.0);

        // At low Vbe the n=2 leakage dominates Ib.
        let eval = q.eval(&[5.0, 0.5, 0.0], &p);
        let ic = eval.g[0];
        let ib = eval.g[1];
        assert!(ic > 0.0 && ib > 0.0, "should be forward active");

        let beta_eff = ic / ib;
        assert!(
            beta_eff < 100.0,
            "recombination should reduce beta: beta_eff={:.4}",
            beta_eff
        );
    }

    /// PNP Jacobian finite-difference check (full 3x3).
    #[test]
    fn bjt_pnp_jacobian_finite_difference() {
        let q = Bjt::pnp();
        let params = npn_params();
        let v = [0.0, 4.3, 5.0];
        let max_err = jacobian_max_rel_err(&q, &v, &params);
        assert!(max_err < 5e-2, "PNP Jacobian max rel err: {max_err}");
    }

    /// Current conservation (KCL) must hold across all operating regions.
    #[test]
    fn bjt_current_conservation_all_regions() {
        let q = Bjt::npn();
        let params = npn_params();

        let test_points: &[[f64; 3]] = &[
            [5.0, 0.7, 0.0],  // forward active
            [0.2, 0.7, 0.0],  // saturation
            [0.0, 0.7, 1.2],  // reverse active
            [0.0, 0.0, 0.0],  // cutoff
            [5.0, 0.85, 0.0], // high injection
        ];

        for v in test_points {
            let eval = q.eval(v, &params);
            let kcl = eval.g[0] + eval.g[1] + eval.g[2];
            assert!(
                kcl.abs() < 1e-6,
                "KCL failed at {:?}: Ic={} Ib={} Ie={} sum={}",
                v,
                eval.g[0],
                eval.g[1],
                eval.g[2],
                kcl
            );
        }
    }

    /// Ebers-Moll fallback (level=0): forward active, KCL, β check.
    #[test]
    fn bjt_ebers_moll_level0_fallback() {
        let q = Bjt::npn();
        let mut p = npn_params();
        p.set("level", 0.0);

        let eval = q.eval(&[5.0, 0.7, 0.0], &p);
        let ic = eval.g[0];
        let ib = eval.g[1];
        let ie = eval.g[2];

        assert!(ic > 0.0, "EM: Ic should be > 0, got {ic}");
        assert!(ib > 0.0, "EM: Ib should be > 0, got {ib}");
        assert!(ie < 0.0, "EM: Ie should be < 0, got {ie}");

        let kcl = ic + ib + ie;
        assert!(kcl.abs() < 1e-6, "EM: KCL violated: {kcl}");

        let beta_eff = ic / ib;
        assert!(
            (beta_eff - 100.0).abs() < 5.0,
            "EM: beta_eff={beta_eff} should be ≈ 100"
        );

        // With level=0, Early effect must be absent: Ic at Vc=1 ≈ Ic at Vc=5.
        let ic1 = q.eval(&[1.0, 0.7, 0.0], &p).g[0];
        let ic5 = q.eval(&[5.0, 0.7, 0.0], &p).g[0];
        let rel = (ic5 - ic1).abs() / ic1.abs().max(1e-30);
        assert!(
            rel < 0.01,
            "EM level=0 should have no Early effect: ic1={ic1} ic5={ic5} rel={rel}"
        );
    }

    /// Ebers-Moll level=0 Jacobian FD check.
    #[test]
    fn bjt_ebers_moll_jacobian_fd() {
        let q = Bjt::npn();
        let mut p = npn_params();
        p.set("level", 0.0);
        let max_err = jacobian_max_rel_err(&q, &[3.0, 0.7, 0.0], &p);
        assert!(max_err < 5e-2, "EM Jacobian FD error: {max_err}");
    }

    /// All 43 standard GP model-card parameters are accepted without panic.
    #[test]
    fn bjt_accepts_full_gp_parameter_set() {
        let q = Bjt::npn();
        let mut p = ParamMap::new();
        // Core transport
        p.set("is", 1e-16);
        p.set("bf", 100.0);
        p.set("nf", 1.0);
        p.set("vaf", 100.0);
        p.set("ikf", 0.1);
        p.set("ise", 1e-14);
        p.set("ne", 1.5);
        p.set("br", 2.0);
        p.set("nr", 1.0);
        p.set("var", 20.0);
        p.set("ikr", 0.01);
        p.set("isc", 1e-14);
        p.set("nc", 2.0);
        // Resistances
        p.set("rb", 100.0);
        p.set("irb", 0.001);
        p.set("rbm", 10.0);
        p.set("re", 1.0);
        p.set("rc", 10.0);
        // Capacitance / transit
        p.set("cje", 1e-12);
        p.set("vje", 0.75);
        p.set("mje", 0.33);
        p.set("tf", 4e-11);
        p.set("xtf", 2.0);
        p.set("vtf", 1.7);
        p.set("itf", 0.6);
        p.set("ptf", 0.0);
        p.set("cjc", 5e-13);
        p.set("vjc", 0.75);
        p.set("mjc", 0.33);
        p.set("xcjc", 0.9);
        p.set("tr", 5e-10);
        p.set("cjs", 2e-12);
        p.set("vjs", 0.75);
        p.set("mjs", 0.0);
        // Temperature / noise
        p.set("xtb", 1.5);
        p.set("eg", 1.11);
        p.set("xti", 3.0);
        p.set("kf", 0.0);
        p.set("af", 1.0);
        p.set("fc", 0.5);
        p.set("vt", 0.02585);
        p.set("tnom", 300.15);
        p.set("level", 1.0);

        // Should produce finite currents without panic.
        let eval = q.eval(&[5.0, 0.7, 0.0], &p);
        assert!(eval.g[0].is_finite());
        assert!(eval.g[1].is_finite());
        assert!(eval.g[2].is_finite());
        let kcl = eval.g[0] + eval.g[1] + eval.g[2];
        assert!(kcl.abs() < 1e-6, "full-params KCL: {kcl}");
    }

    #[test]
    fn bjt_xtf_itf_modulates_tf_without_finite_vtf() {
        let q = Bjt::npn();
        let mut p_base = npn_params();
        p_base.set("tf", 1e-9);

        let mut p_xtf = p_base.clone();
        p_xtf.set("xtf", 3.0);
        p_xtf.set("itf", 1e-4);

        let voltages = [5.0, 0.85, 0.0];
        let eval_base = q.eval(&voltages, &p_base);
        let eval_xtf = q.eval(&voltages, &p_xtf);

        assert!(
            eval_xtf.q[1] > eval_base.q[1],
            "xtf/itf should increase forward transit charge even when VTF is omitted: base={} xtf={}",
            eval_base.q[1],
            eval_xtf.q[1]
        );
        assert!(
            (eval_xtf.q[0] + eval_xtf.q[1] + eval_xtf.q[2]).abs() < 1e-24,
            "charge KCL violated: {:?}",
            eval_xtf.q
        );
    }

    #[test]
    fn bjt_tf_capacitance_matches_charge_fd_with_xtf_itf() {
        let q = Bjt::npn();
        let mut p = npn_params();
        p.set("tf", 8e-10);
        p.set("xtf", 2.5);
        p.set("itf", 2e-4);
        p.set("vtf", 1.2);

        let v = [4.0, 0.82, 0.0];
        let h = 1e-7;
        let eval0 = q.eval(&v, &p);

        let mut vp = v;
        let mut vm = v;
        vp[1] += h;
        vm[1] -= h;
        let eval_p = q.eval(&vp, &p);
        let eval_m = q.eval(&vm, &p);

        let dq_base_dvb_fd = (eval_p.q[1] - eval_m.q[1]) / (2.0 * h);
        let dq_emit_dvb_fd = (eval_p.q[2] - eval_m.q[2]) / (2.0 * h);
        let c_base_vb = cap_entry_sum(&eval0, 1, 1);
        let c_emit_vb = cap_entry_sum(&eval0, 2, 1);

        let base_rel_err = (dq_base_dvb_fd - c_base_vb).abs()
            / c_base_vb.abs().max(dq_base_dvb_fd.abs()).max(1e-20);
        let emit_rel_err = (dq_emit_dvb_fd - c_emit_vb).abs()
            / c_emit_vb.abs().max(dq_emit_dvb_fd.abs()).max(1e-20);

        assert!(
            base_rel_err < 2e-3,
            "base dq/dVb mismatch: fd={dq_base_dvb_fd:.6e} analytic={c_base_vb:.6e} rel={base_rel_err:.2e}"
        );
        assert!(
            emit_rel_err < 2e-3,
            "emitter dq/dVb mismatch: fd={dq_emit_dvb_fd:.6e} analytic={c_emit_vb:.6e} rel={emit_rel_err:.2e}"
        );
    }

    // ── Transient charge tests (TODO §3) ──────────────────────────────────────

    /// NPN BJT in active region (Vbe=0.7, Vce=2.0):
    /// q_be (base charge, pin 1 q[]) must be positive and of order tau_f * Ic.
    ///
    /// From the GP model:
    ///   q[1] = q_tf + q_tr + q_cje + q_cjc
    /// With tf=1e-10, Ic ≈ several µA, q_be ≈ tf * Ic ~ 1e-10 * 1e-6 = 1e-16 C.
    #[test]
    fn test_bjt_transient_q_be_nonzero() {
        let q = Bjt::npn();
        let mut p = npn_params();
        // Set tf so forward transit charge is non-trivial.
        let tf = 1e-10_f64; // 100 ps forward transit time
        p.set("tf", tf);
        p.set("cje", 1e-12); // 1 pF BE depletion cap (adds to q_be)

        // Forward active: Vc=2.0, Vb=0.7, Ve=0.
        let eval = q.eval(&[2.0, 0.7, 0.0], &p);

        let q_be = eval.q[1]; // base charge = q_tf + q_cje (+ any q_tr, q_cjc ≈ 0)

        // Must be positive and non-trivial.
        assert!(
            q_be > 0.0,
            "q_be (base charge, q[1]) must be > 0 in forward active, got {q_be}"
        );

        // Lower bound: at least the depletion charge (Cje * Vbe ≈ 1e-12 * 0.75*... linear approx).
        // At Vbe=0.7 < FC*VJE=0.5*0.75=0.375 false; actually 0.7 > 0.375 so linearized region.
        // Just check order-of-magnitude: q_be should be at least 1e-16 C.
        assert!(
            q_be > 1e-20,
            "q_be should be significant (> 1e-20 C), got {q_be:.3e}"
        );

        // Upper bound: no runaway (< 1 C is a generous sanity check).
        assert!(q_be < 1.0, "q_be unreasonably large: {q_be}");

        // Verify the transit charge contribution: q_tf ≈ tf * Ic_intrinsic.
        // We can bound it: with Is=1e-16, Vbe=0.7, Ic ≈ Is*exp(0.7/0.02585) ~ µA range.
        // tf * Ic ~ 1e-10 * 1e-6 = 1e-16.  The total q_be should be at least this order.
        let ic = eval.g[0]; // collector current
        assert!(ic > 0.0, "forward active: Ic must be > 0");
        // q_be should be at least 50% of tf*Ic (rest could be CJE charge on top).
        let q_tf_expected = tf * ic;
        assert!(
            q_be >= q_tf_expected * 0.5,
            "q_be={q_be:.3e} should be at least tf*Ic={q_tf_expected:.3e}"
        );
    }

    /// Verify that the capacitance matrix C has nonzero entries for BE and BC
    /// junctions when the BJT is in the active region with CJE and TF set.
    ///
    /// Specifically:
    ///   - C[1,1] (dQ_base/dVb) must be > 0 (positive capacitance at base)
    ///   - C[2,2] (dQ_emitter/dVe) must be > 0 (positive capacitance at emitter)
    #[test]
    fn test_bjt_companion_stamp_capacitance() {
        let q = Bjt::npn();
        let mut p = npn_params();
        p.set("tf", 5e-11);  // 50 ps
        p.set("cje", 5e-13); // 0.5 pF BE depletion cap
        p.set("vje", 0.75);
        p.set("mje", 0.33);
        p.set("fc", 0.5);

        // Active region: Vc=3, Vb=0.7, Ve=0.
        let eval = q.eval(&[3.0, 0.7, 0.0], &p);

        // C[1,1] = dQ_base/dVb — must be positive (base sees capacitance to itself).
        let c_bb = cap_entry_sum(&eval, 1, 1);
        assert!(
            c_bb > 0.0,
            "C[1,1] = dQ_base/dVb must be > 0, got {c_bb:.3e}"
        );

        // C[2,2] = dQ_emitter/dVe — must be positive (emitter cap).
        let c_ee = cap_entry_sum(&eval, 2, 2);
        assert!(
            c_ee > 0.0,
            "C[2,2] = dQ_emitter/dVe must be > 0, got {c_ee:.3e}"
        );

        // C[1,2] = dQ_base/dVe should be negative (cross-term from CJE).
        let c_be = cap_entry_sum(&eval, 1, 2);
        assert!(
            c_be < 0.0,
            "C[1,2] = dQ_base/dVe must be < 0 (CJE cross-term), got {c_be:.3e}"
        );

        // Charge KCL: sum of all pin charges must be ~ 0 (charge neutrality).
        let q_sum: f64 = eval.q.iter().sum();
        assert!(
            q_sum.abs() < 1e-20,
            "charge KCL: q_C + q_B + q_E = {q_sum:.3e} ≠ 0"
        );
    }

    // ── Additional BJT physics tests ──────────────────────────────────────────

    /// NPN forward active: Ic ≈ Is * BF * exp(Vbe/Vt) for large Vce.
    /// With BF=100, IS=1e-16, VBE=0.7, VT=0.02585:
    ///   Ic ≈ IS * exp(VBE/VT) (since qb≈1 with no Early, Icc ≈ If ≈ IS*exp(VBE/VT))
    #[test]
    fn bjt_npn_ic_analytic_forward_active() {
        let q = Bjt::npn();
        let is = 1e-16_f64;
        let vt = 0.02585_f64;
        let vbe = 0.7_f64;
        let mut p = npn_params();
        p.set("is", is);
        // Vc=5 (large enough to be in forward active), Vb=0.7, Ve=0
        let eval = q.eval(&[5.0, vbe, 0.0], &p);
        let ic_expected = is * (vbe / vt).exp();
        let ic_actual = eval.g[0];
        let rel_err = (ic_actual - ic_expected).abs() / ic_expected.abs().max(1e-30);
        assert!(
            rel_err < 0.05,
            "Ic analytic: got {ic_actual:.6e}, expected {ic_expected:.6e}, rel_err={rel_err:.3e}"
        );
    }

    /// NPN cutoff: Vbe=0 (no injection) → Ic, Ib, Ie all near zero.
    #[test]
    fn bjt_npn_cutoff_zero_vbe() {
        let q = Bjt::npn();
        let p = npn_params();
        // Vbe=0, Vbc=0 → pure cutoff
        let eval = q.eval(&[3.0, 0.0, 0.0], &p);
        assert!(eval.g[0].abs() < 1e-8, "Ic in cutoff: {}", eval.g[0]);
        assert!(eval.g[1].abs() < 1e-8, "Ib in cutoff: {}", eval.g[1]);
        assert!(eval.g[2].abs() < 1e-8, "Ie in cutoff: {}", eval.g[2]);
    }

    /// NPN saturation: both junctions forward biased → beta < Bf.
    #[test]
    fn bjt_npn_saturation_beta_reduced() {
        let q = Bjt::npn();
        let p = npn_params();
        // Vbe=0.7 (forward), Vbc=0.5 (forward) → saturation
        let eval = q.eval(&[0.2, 0.7, 0.0], &p);
        let ic = eval.g[0];
        let ib = eval.g[1];
        assert!(ic > 0.0 && ib > 0.0, "sat: both Ic and Ib must be positive");
        let beta_eff = ic / ib;
        assert!(
            beta_eff < 100.0,
            "sat: beta_eff={:.2} must be < Bf=100",
            beta_eff
        );
    }

    /// PNP forward active: all current signs reversed vs NPN.
    #[test]
    fn bjt_pnp_forward_active_signs() {
        let q = Bjt::pnp();
        let p = npn_params();
        // PNP forward active: Ve=5V, Vb=4.3V, Vc=0V → Vbe_eff=0.7, Vce_eff=-4.3
        let eval = q.eval(&[0.0, 4.3, 5.0], &p);
        // Collector receives current (Ic < 0 for PNP convention), Ie sources it
        assert!(eval.g[0] < 0.0, "PNP Ic should be < 0, got {}", eval.g[0]);
        assert!(eval.g[2] > 0.0, "PNP Ie should be > 0, got {}", eval.g[2]);
        // KCL
        let kcl = eval.g[0] + eval.g[1] + eval.g[2];
        assert!(kcl.abs() < 1e-6, "PNP KCL violated: {kcl}");
    }

    /// PNP saturation: both junctions forward biased → Ic still negative but |Ic|/|Ib| < Bf.
    #[test]
    fn bjt_pnp_saturation() {
        let q = Bjt::pnp();
        let p = npn_params();
        // PNP sat: Vc=4.5, Vb=4.3, Ve=5 → Vbe_pnp = p*(Vb-Ve) = -0.7 (forward)
        //          Vbc_pnp = p*(Vb-Vc) = -(-0.2) = +0.2 → Vbc_phys=0.2 V (forward)
        let eval = q.eval(&[4.5, 4.3, 5.0], &p);
        let ic = eval.g[0];
        let ib = eval.g[1];
        // In PNP saturation both junctions forward: Ic < 0, Ib < 0
        assert!(ic < 0.0, "PNP sat: Ic should be < 0, got {ic}");
        assert!(ib < 0.0, "PNP sat: Ib should be < 0, got {ib}");
        let beta_eff = ic.abs() / ib.abs();
        assert!(
            beta_eff < 100.0,
            "PNP sat: |Ic|/|Ib|={beta_eff:.2} should be < Bf=100"
        );
        // KCL
        let kcl = eval.g[0] + eval.g[1] + eval.g[2];
        assert!(kcl.abs() < 1e-6, "PNP sat KCL: {kcl}");
    }

    /// NPN: Increasing VBE → increasing Ic (exponential characteristic).
    #[test]
    fn bjt_npn_ic_increases_with_vbe() {
        let q = Bjt::npn();
        let p = npn_params();
        let vbe_vals = [0.5_f64, 0.6, 0.65, 0.7];
        let mut ic_prev = 0.0_f64;
        for &vbe in &vbe_vals {
            let eval = q.eval(&[5.0, vbe, 0.0], &p);
            let ic = eval.g[0];
            assert!(ic > ic_prev, "Ic should increase with Vbe: at Vbe={vbe} got {ic}, prev={ic_prev}");
            ic_prev = ic;
        }
    }

    /// NPN: Jacobian FD check in forward active, all 9 entries.
    #[test]
    fn bjt_npn_full_jacobian_fd_forward_active() {
        let q = Bjt::npn();
        let p = npn_params();
        let v = [5.0_f64, 0.7, 0.0];
        let max_err = jacobian_max_rel_err(&q, &v, &p);
        assert!(max_err < 5e-2, "NPN forward active Jacobian FD: {max_err}");
    }

    /// NPN: Jacobian FD check in cutoff region.
    #[test]
    fn bjt_npn_jacobian_fd_cutoff() {
        let q = Bjt::npn();
        let p = npn_params();
        let v = [3.0_f64, 0.0, 0.0];
        let max_err = jacobian_max_rel_err(&q, &v, &p);
        assert!(max_err < 5e-2, "NPN cutoff Jacobian FD: {max_err}");
    }

    /// NPN: Jacobian FD check in saturation.
    #[test]
    fn bjt_npn_jacobian_fd_saturation() {
        let q = Bjt::npn();
        let p = npn_params();
        let v = [0.2_f64, 0.7, 0.0];
        let max_err = jacobian_max_rel_err(&q, &v, &p);
        assert!(max_err < 5e-2, "NPN saturation Jacobian FD: {max_err}");
    }

    /// KCL holds for multiple operating points simultaneously.
    #[test]
    fn bjt_kcl_multiple_bias_points() {
        let q = Bjt::npn();
        let p = npn_params();
        let points: &[[f64; 3]] = &[
            [0.0, 0.0, 0.0],
            [3.0, 0.5, 0.0],
            [3.0, 0.6, 0.0],
            [3.0, 0.7, 0.0],
            [0.2, 0.7, 0.0],
            [0.0, 0.7, 1.2],
        ];
        for v in points {
            let eval = q.eval(v, &p);
            let kcl = eval.g[0] + eval.g[1] + eval.g[2];
            assert!(
                kcl.abs() < 1e-6,
                "KCL violated at {:?}: {kcl}",
                v
            );
        }
    }

    /// NPN: BF scaling — doubling BF roughly doubles Ic/Ib.
    #[test]
    fn bjt_npn_bf_scaling() {
        let q = Bjt::npn();
        let mut p100 = npn_params();
        p100.set("bf", 100.0);
        let mut p200 = npn_params();
        p200.set("bf", 200.0);
        let v = [5.0_f64, 0.7, 0.0];
        let e100 = q.eval(&v, &p100);
        let e200 = q.eval(&v, &p200);
        // Ib should halve (since Ib = If/Bf) when Bf doubles
        let ib_ratio = e100.g[1] / e200.g[1];
        assert!(
            (ib_ratio - 2.0).abs() < 0.3,
            "doubling Bf should halve Ib: ratio={ib_ratio:.3}"
        );
    }

    /// NPN IS scaling: doubling IS should double Ic at same Vbe.
    #[test]
    fn bjt_npn_is_scaling() {
        let q = Bjt::npn();
        let mut p1 = npn_params();
        p1.set("is", 1e-16);
        let mut p2 = npn_params();
        p2.set("is", 2e-16);
        let v = [5.0_f64, 0.7, 0.0];
        let e1 = q.eval(&v, &p1);
        let e2 = q.eval(&v, &p2);
        let ratio = e2.g[0] / e1.g[0];
        assert!(
            (ratio - 2.0).abs() < 0.1,
            "doubling IS should double Ic: ratio={ratio:.4}"
        );
    }

    /// NPN: overflow protection — extreme VBE produces finite results.
    #[test]
    fn bjt_npn_overflow_protection_extreme_vbe() {
        let q = Bjt::npn();
        let p = npn_params();
        // Very high VBE — must not overflow
        let eval = q.eval(&[5.0, 100.0, 0.0], &p);
        assert!(eval.g[0].is_finite(), "Ic must be finite at extreme Vbe");
        assert!(eval.g[1].is_finite(), "Ib must be finite at extreme Vbe");
        assert!(eval.g[2].is_finite(), "Ie must be finite at extreme Vbe");
    }

    /// CJC stamps capacitance between collector and base nodes.
    #[test]
    fn bjt_cjc_stamps_bc_capacitance() {
        let q = Bjt::npn();
        let mut p = npn_params();
        p.set("cjc", 1e-12);
        p.set("vjc", 0.75);
        p.set("mjc", 0.33);
        p.set("fc", 0.5);
        // Reverse-biased BC junction: Vc=5, Vb=0.7, Ve=0
        let eval = q.eval(&[5.0, 0.7, 0.0], &p);
        // Capacitance should stamp C[0,0] (collector) and C[1,1] (base) entries
        let c00 = cap_entry_sum(&eval, 0, 0);
        let c11_bc = cap_entry_sum(&eval, 1, 0); // cross term base-collector
        assert!(c00 > 0.0, "CJC: C[0,0] should be > 0, got {c00:.3e}");
        assert!(c11_bc < 0.0, "CJC: C[1,0] should be < 0, got {c11_bc:.3e}");
    }

    /// CJS stamps collector-substrate capacitance on pin 0.
    #[test]
    fn bjt_cjs_stamps_collector_substrate_cap() {
        let q = Bjt::npn();
        let mut p = npn_params();
        p.set("cjs", 2e-12);
        p.set("vjs", 0.75);
        p.set("mjs", 0.0);
        let eval = q.eval(&[5.0, 0.7, 0.0], &p);
        // CJS stamps C[0,0] (collector to substrate = ground)
        let c_col = cap_entry_sum(&eval, 0, 0);
        assert!(c_col > 0.0, "CJS should add capacitance on pin 0 (collector), got {c_col:.3e}");
    }

    /// Temperature scaling: at elevated temp, Is is larger → more Ic at same Vbe.
    #[test]
    fn bjt_temperature_scaling_increases_ic() {
        let q = Bjt::npn();
        let mut p_nom = npn_params();
        p_nom.remove("vt"); // remove explicit vt so temp scaling applies
        p_nom.set("temp", 300.15);
        p_nom.set("tnom", 300.15);
        p_nom.set("is", 1e-16);
        p_nom.set("xti", 3.0);
        p_nom.set("eg", 1.11);

        let mut p_hot = p_nom.clone();
        p_hot.set("temp", 350.15); // +50K

        let v = [5.0_f64, 0.65, 0.0];
        let eval_nom = q.eval(&v, &p_nom);
        let eval_hot = q.eval(&v, &p_hot);

        assert!(
            eval_hot.g[0] > eval_nom.g[0],
            "elevated temp should increase Ic: nom={} hot={}",
            eval_nom.g[0],
            eval_hot.g[0]
        );
    }

    /// NPN in deep cutoff with negative VBE: no injection at all.
    #[test]
    fn bjt_npn_deep_cutoff_negative_vbe() {
        let q = Bjt::npn();
        let p = npn_params();
        // VBE = -1V, VBC = -5V → deep cutoff
        let eval = q.eval(&[5.0, -1.0, 0.0], &p);
        // Only GMIN leakage: at V=-1V, GMIN*(-1V)≈-1e-12 A
        assert!(
            eval.g[0].abs() < 1e-9,
            "deep cutoff Ic should be near zero, got {}",
            eval.g[0]
        );
    }

    /// NPN: PNP with the mirror-image bias produces the mirror-image currents.
    /// NPN: Vc=5, Vb=0.7, Ve=0 → Ic>0
    /// PNP: Vc=0, Vb=4.3, Ve=5 → Vbe_pnp=p*(Vb-Ve)=-1*(4.3-5)=0.7 (forward), Ic<0.
    #[test]
    fn bjt_npn_pnp_mirror_symmetry() {
        let npn = Bjt::npn();
        let pnp = Bjt::pnp();
        let p = npn_params();
        // NPN forward active
        let e_npn = npn.eval(&[5.0, 0.7, 0.0], &p);
        // PNP forward active with equal-magnitude biasing
        // PNP: pin0=Vc, pin1=Vb, pin2=Ve → Vc=0, Vb=4.3, Ve=5
        // vbe_pnp = p*(Vb-Ve) = -1*(4.3-5) = 0.7 (forward) ✓
        // vbc_pnp = p*(Vb-Vc) = -1*(4.3-0) = -4.3 (reverse) ✓ → forward active
        let e_pnp = pnp.eval(&[0.0, 4.3, 5.0], &p);
        // NPN: Ic > 0; PNP: Ic < 0
        assert!(e_npn.g[0] > 0.0, "NPN Ic > 0, got {}", e_npn.g[0]);
        assert!(e_pnp.g[0] < 0.0, "PNP mirrored Ic < 0, got {}", e_pnp.g[0]);
        // Same |Vbe| and |Vce| → same |Ic|
        let ratio = e_npn.g[0].abs() / e_pnp.g[0].abs();
        assert!(
            (ratio - 1.0).abs() < 0.01,
            "NPN/PNP Ic magnitudes should match: npn={} pnp={}",
            e_npn.g[0],
            e_pnp.g[0]
        );
    }

    // ── Cje/Cjc companion model accuracy tests ────────────────────────────────

    /// CJE (BE depletion cap) must produce non-zero q[1] (base charge) and
    /// non-zero q[2] (emitter charge) at forward bias when cje is set.
    ///
    /// With cje=1e-12, vje=0.75, mje=0.33 at Vbe=0.7V (forward):
    ///   Q_cje = integral of C(v) dv > 0  (charge on base is positive, on emitter negative)
    #[test]
    fn bjt_cje_nonzero_charge_at_forward_bias() {
        let q = Bjt::npn();
        let mut p = npn_params();
        p.set("cje", 1e-12);  // 1 pF BE zero-bias depletion cap
        p.set("vje", 0.75);
        p.set("mje", 0.33);
        p.set("fc", 0.5);

        // Forward-biased BE: Vc=5, Vb=0.7, Ve=0 → Vbe=0.7V (forward active)
        let eval = q.eval(&[5.0, 0.7, 0.0], &p);

        // q[1] (base): includes +q_cje; must be > 0 (cje dominates at forward bias)
        let q_base = eval.q[1];
        assert!(
            q_base > 0.0,
            "CJE: q[1] (base charge) must be > 0 at Vbe=0.7V with cje=1e-12, got {q_base:.3e}"
        );

        // q[2] (emitter): includes -q_cje; must be < 0
        let q_emit = eval.q[2];
        assert!(
            q_emit < 0.0,
            "CJE: q[2] (emitter charge) must be < 0 at Vbe=0.7V with cje=1e-12, got {q_emit:.3e}"
        );

        // Charge magnitude sanity: linear approx gives Q ~ cje * Vbe ~ 1e-12 * 0.7 = 7e-13
        // The actual depletion formula gives somewhat less; require at least 1e-14 C.
        assert!(
            q_base > 1e-14,
            "CJE charge too small: q_base={q_base:.3e}, expected > 1e-14 C"
        );

        // Charge KCL for the three pins (no CJC set, so balance is CJE only).
        let q_sum: f64 = eval.q.iter().sum();
        assert!(
            q_sum.abs() < 1e-22,
            "charge KCL: q[0]+q[1]+q[2] = {q_sum:.3e}, should be ~0"
        );
    }

    /// CJC (BC depletion cap) must produce non-zero charges and C entries
    /// at zero or reverse bias when cjc is set.
    ///
    /// At Vbc=0 (zero bias): Q_cjc = 0, but C_bc_dep = cjc (unscaled, max capacitance).
    /// At Vbc=-5V (reverse bias): Q_cjc > 0 (accumulated on collector), C_bc_dep > 0.
    #[test]
    fn bjt_cjc_nonzero_at_zero_and_reverse_bias() {
        let q = Bjt::npn();
        let mut p = npn_params();
        p.set("cjc", 1e-12);  // 1 pF BC zero-bias depletion cap
        p.set("vjc", 0.75);
        p.set("mjc", 0.33);
        p.set("fc", 0.5);

        // At Vbc = 0 (Vc=0.7, Vb=0.7, Ve=0 → Vbe=0.7, Vbc=0): reverse-bias part of q is 0,
        // but differential capacitance C_bc_dep = cjc * (1-0/vjc)^(-mjc) = cjc (= 1e-12).
        let eval_zero = q.eval(&[0.7, 0.7, 0.0], &p);
        let c00_zero = cap_entry_sum(&eval_zero, 0, 0);  // collector diagonal (CJC contributes)
        assert!(
            c00_zero > 0.0,
            "CJC at Vbc=0: C[0,0] must be > 0 (capacitance is cjc at zero bias), got {c00_zero:.3e}"
        );

        // At Vbc = -5V (Vc=5.7, Vb=0.7, Ve=0): BC strongly reverse-biased.
        // Q_cjc = cjc*vjc/(1-mjc) * [1 - (1 - (-5)/vjc)^(1-mjc)] > 0.
        // The charge on collector is -q_cjc (negative: reversed sign), and on base +q_cjc.
        let eval_rev = q.eval(&[5.7, 0.7, 0.0], &p);

        // C[0,0] at reverse bias: collector diagonal must be > 0 (CJC capacitance).
        let c00_rev = cap_entry_sum(&eval_rev, 0, 0);
        assert!(
            c00_rev > 0.0,
            "CJC at reverse bias: C[0,0] must be > 0, got {c00_rev:.3e}"
        );

        // C[1,0] (base row, collector col): cross-capacitance must be < 0 (anti-symmetric).
        let c10_rev = cap_entry_sum(&eval_rev, 1, 0);
        assert!(
            c10_rev < 0.0,
            "CJC: C[1,0] cross-cap must be < 0, got {c10_rev:.3e}"
        );

        // q[0] collector at reverse bias: collector charge = -q_cjc (negative, since CJC
        // stores charge on base side). q[1] + q[0] contributions from CJC should cancel.
        let q_sum: f64 = eval_rev.q.iter().sum();
        assert!(
            q_sum.abs() < 1e-22,
            "CJC reverse bias charge KCL: sum={q_sum:.3e}"
        );
    }

    /// Verify q vector has non-zero entries for both BE and BC junction pairs
    /// when both cje and cjc are set at a forward-active operating point.
    ///
    /// NPN forward active: Vc=3, Vb=0.7, Ve=0 → Vbe=+0.7V (forward), Vbc=-2.3V (reverse).
    ///
    /// Sign conventions (from DeviceEval assembly):
    ///   q[1] (base)     = +q_cje + q_cjc  — both positive at forward/zero Vbe
    ///   q[2] (emitter)  = -q_cje          — negative (drain from emitter side)
    ///   q[0] (collector) = -q_cjc          — sign of q_cjc from junction_qc at reverse Vbc
    ///
    /// At reverse Vbc: junction_qc returns a negative charge (Q<0 for V<0), so
    /// q[0] = -q_cjc = -(negative) > 0, and q[1] += q_cjc = negative contribution,
    /// but the CJE dominates at forward Vbe so q[1] > 0 overall.
    ///
    /// The key invariant to check is:
    ///   - q[1] and q[0] are both non-zero (both junctions have charge storage)
    ///   - q[1] + q[2] + q[0] = 0 (charge KCL)
    ///   - C matrix has non-zero entries for both BE pair (pins 1,2) and BC pair (pins 0,1)
    #[test]
    fn bjt_q_vector_nonzero_for_be_and_bc_junctions() {
        let q = Bjt::npn();
        let mut p = npn_params();
        p.set("cje", 2e-12);  // 2 pF BE zero-bias depletion cap
        p.set("vje", 0.75);
        p.set("mje", 0.33);
        p.set("cjc", 5e-13);  // 0.5 pF BC zero-bias depletion cap
        p.set("vjc", 0.75);
        p.set("mjc", 0.33);
        p.set("fc", 0.5);

        // Forward active: Vc=3, Vb=0.7, Ve=0
        // Vbe=0.7V (forward), Vbc = 0.7-3 = -2.3V (reverse) in NPN terms.
        let eval = q.eval(&[3.0, 0.7, 0.0], &p);

        // q[1] (base): includes +q_cje (large, forward bias) and +q_cjc (negative at reverse
        // bias, so net base contribution from CJC is negative). CJE dominates → q[1] > 0.
        let q_base = eval.q[1];
        assert!(
            q_base > 0.0,
            "q[1] (base) must be > 0 at Vbe=0.7V with cje=2e-12 dominating, got {q_base:.3e}"
        );

        // q[2] (emitter): = -q_cje, must be negative.
        let q_emit = eval.q[2];
        assert!(
            q_emit < 0.0,
            "q[2] (emitter) must be < 0 (-q_cje at forward Vbe), got {q_emit:.3e}"
        );

        // q[0] (collector): = -q_cjc. At reverse Vbc=-2.3V, junction_qc returns q_cjc < 0
        // (depletion region expands, stored charge is negative by SPICE convention at V<0).
        // So -q_cjc = -(negative) > 0.
        let q_coll = eval.q[0];
        assert!(
            q_coll.abs() > 1e-25,
            "q[0] (collector) must be non-zero with cjc=5e-13, got {q_coll:.3e}"
        );

        // Charge KCL: all three pin charges must sum to zero.
        let q_sum = q_base + q_emit + q_coll;
        assert!(
            q_sum.abs() < 1e-22,
            "Charge KCL (q[0]+q[1]+q[2]): got {q_sum:.3e}, expected ~0"
        );

        // C matrix: BE junction — C[1,1] > 0 (base self-capacitance from CJE+CJC).
        let c_bb = cap_entry_sum(&eval, 1, 1);
        assert!(
            c_bb > 0.0,
            "C[1,1] must be > 0 (CJE + CJC capacitance at base), got {c_bb:.3e}"
        );

        // C matrix: BC junction — C[0,0] > 0 (collector self-capacitance from CJC).
        let c_cc = cap_entry_sum(&eval, 0, 0);
        assert!(
            c_cc > 0.0,
            "C[0,0] must be > 0 (CJC capacitance at collector), got {c_cc:.3e}"
        );

        // C matrix: BE cross-term C[1,2] < 0 (from CJE anti-symmetric stamp).
        let c_be_cross = cap_entry_sum(&eval, 1, 2);
        assert!(
            c_be_cross < 0.0,
            "C[1,2] must be < 0 (CJE cross-cap base→emitter), got {c_be_cross:.3e}"
        );

        // C matrix: BC cross-term C[1,0] < 0 (from CJC anti-symmetric stamp).
        let c_bc_cross = cap_entry_sum(&eval, 1, 0);
        assert!(
            c_bc_cross < 0.0,
            "C[1,0] must be < 0 (CJC cross-cap base→collector), got {c_bc_cross:.3e}"
        );
    }

    /// Verify the Cje junction charge formula accuracy via finite-difference of q vs C.
    ///
    /// At the operating point, dq_cje/dVbe should equal c_be_dep (the depletion capacitance).
    /// We verify this by checking that dq[1]/dVb (FD) matches C[1,1] from CJE only.
    #[test]
    fn bjt_cje_charge_derivative_matches_capacitance() {
        let q = Bjt::npn();
        let mut p = npn_params();
        // Only CJE — no TF, no CJC — so q[1] = q_cje and C[1,1] = c_be_dep.
        p.set("cje", 1e-12);
        p.set("vje", 0.75);
        p.set("mje", 0.33);
        p.set("fc", 0.5);

        // Bias below linearization threshold: Vbe=0.3V < FC*VJE=0.375V → exact formula region.
        let v = [5.0_f64, 0.3, 0.0]; // Vbe=0.3V, Vbc=-4.7V (reverse)
        let h = 1e-7_f64;

        let mut vp = v;
        let mut vm = v;
        vp[1] += h; // perturb Vb up → Vbe increases
        vm[1] -= h;

        let eval0 = q.eval(&v, &p);
        let eval_p = q.eval(&vp, &p);
        let eval_m = q.eval(&vm, &p);

        // FD: dq_base/dVb ≈ (q_base(Vb+h) - q_base(Vb-h)) / (2h)
        let dq_base_dvb_fd = (eval_p.q[1] - eval_m.q[1]) / (2.0 * h);

        // Analytic: C[1,1] from the eval (includes CJE contribution only since TF=0, CJC=0).
        let c_base_vb = cap_entry_sum(&eval0, 1, 1);

        let rel_err = (dq_base_dvb_fd - c_base_vb).abs()
            / c_base_vb.abs().max(dq_base_dvb_fd.abs()).max(1e-20);

        assert!(
            rel_err < 5e-3,
            "CJE: dq_base/dVb mismatch: fd={dq_base_dvb_fd:.6e} analytic={c_base_vb:.6e} rel={rel_err:.2e}"
        );

        // Also check the emitter side: dq_emit/dVe should equal C[2,2].
        let dq_emit_dve_fd = {
            let mut vpe = v;
            let mut vme = v;
            vpe[2] += h;
            vme[2] -= h;
            let ep = q.eval(&vpe, &p);
            let em = q.eval(&vme, &p);
            (ep.q[2] - em.q[2]) / (2.0 * h)
        };
        let c_emit_ve = cap_entry_sum(&eval0, 2, 2);
        let rel_err_e = (dq_emit_dve_fd - c_emit_ve).abs()
            / c_emit_ve.abs().max(dq_emit_dve_fd.abs()).max(1e-20);
        assert!(
            rel_err_e < 5e-3,
            "CJE emitter: dq_emit/dVe mismatch: fd={dq_emit_dve_fd:.6e} analytic={c_emit_ve:.6e} rel={rel_err_e:.2e}"
        );
    }

    /// Verify Cjc junction charge formula accuracy via finite-difference.
    ///
    /// At a reverse-biased BC operating point, dq_cjc/dVbc should equal c_bc_dep.
    /// We check dq[0]/dVc (collector charge vs collector voltage) matches C[0,0].
    #[test]
    fn bjt_cjc_charge_derivative_matches_capacitance() {
        let q = Bjt::npn();
        let mut p = npn_params();
        // Only CJC — no TF, no CJE — so q[0] = -q_cjc and C[0,0] = c_bc_dep.
        p.set("cjc", 1e-12);
        p.set("vjc", 0.75);
        p.set("mjc", 0.33);
        p.set("fc", 0.5);

        // Reverse-biased BC: Vc=3, Vb=0.7, Ve=0 → Vbc = 0.7-3 = -2.3V (reverse).
        // At -2.3V, (1 - (-2.3)/0.75) = 1 + 3.07 = 4.07 > 0, well in depletion formula range.
        let v = [3.0_f64, 0.7, 0.0];
        let h = 1e-7_f64;

        let eval0 = q.eval(&v, &p);

        // Perturb Vc (pin 0): dVbc/dVc = -p = -1 for NPN, so increasing Vc decreases Vbc.
        let mut vp = v;
        let mut vm = v;
        vp[0] += h;
        vm[0] -= h;
        let eval_p = q.eval(&vp, &p);
        let eval_m = q.eval(&vm, &p);

        // FD: dq_coll/dVc.  q[0] = -q_cjc, and as Vc rises Vbc falls (more reverse),
        // so q_cjc increases and q[0] becomes more negative → dq[0]/dVc < 0.
        let dq_coll_dvc_fd = (eval_p.q[0] - eval_m.q[0]) / (2.0 * h);

        // Analytic: C[0,0] entry. Because q[0]=-q_cjc and dVbc/dVc=-1,
        // dq[0]/dVc = -dq_cjc/dVbc * dVbc/dVc = -c_bc_dep * (-1) = +c_bc_dep.
        // So C[0,0] should equal c_bc_dep (> 0), and FD should also be > 0 ... but
        // let's just compare the two directly; they should match in sign and magnitude.
        let c_coll_vc = cap_entry_sum(&eval0, 0, 0);

        let rel_err = (dq_coll_dvc_fd - c_coll_vc).abs()
            / c_coll_vc.abs().max(dq_coll_dvc_fd.abs()).max(1e-20);

        assert!(
            rel_err < 5e-3,
            "CJC: dq_coll/dVc mismatch: fd={dq_coll_dvc_fd:.6e} analytic={c_coll_vc:.6e} rel={rel_err:.2e}"
        );

        // Symmetry: dq_base/dVb should match C[1,1] (base self-cap from CJC).
        let dq_base_dvb_fd = {
            let mut vp2 = v;
            let mut vm2 = v;
            vp2[1] += h;
            vm2[1] -= h;
            let ep = q.eval(&vp2, &p);
            let em = q.eval(&vm2, &p);
            (ep.q[1] - em.q[1]) / (2.0 * h)
        };
        let c_base_vb = cap_entry_sum(&eval0, 1, 1);
        let rel_err_b = (dq_base_dvb_fd - c_base_vb).abs()
            / c_base_vb.abs().max(dq_base_dvb_fd.abs()).max(1e-20);
        assert!(
            rel_err_b < 5e-3,
            "CJC base: dq_base/dVb mismatch: fd={dq_base_dvb_fd:.6e} analytic={c_base_vb:.6e} rel={rel_err_b:.2e}"
        );
    }
}
