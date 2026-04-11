use smallvec::{SmallVec, smallvec};
use bigospice_core::{DeviceKind, ParamMap};

use crate::eval::{DeviceEval, DeviceModel};

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
        if (temp - tnom).abs() < 1e-6 { return is_nom; }
        let vt_t = Self::KB * temp / Self::Q;
        let ratio = temp / tnom;
        is_nom * ratio.powf(xti / nf) * ((eg / nf) * (ratio - 1.0) / vt_t).exp()
    }

    #[inline]
    fn temperature_scale_beta(beta: f64, temp: f64, tnom: f64, xtb: f64) -> f64 {
        if (temp - tnom).abs() < 1e-6 || xtb == 0.0 { return beta; }
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
        let is  = params.get_or("is",  1e-16);
        let bf  = params.get_or("bf",  100.0);
        let nf  = params.get_or("nf",  1.0);
        let br  = params.get_or("br",  1.0);
        let nr  = params.get_or("nr",  1.0);
        let vt  = params.get_or("vt",  Self::DEFAULT_VT);

        let nf_vt = nf * vt;
        let nr_vt = nr * vt;
        let p     = self.polarity;

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
        let dic_dvbe =  g_f;
        let dic_dvbc = -g_r - g_r * inv_br;
        let dib_dvbe =  g_f * inv_bf;
        let dib_dvbc =  g_r * inv_br;
        let die_dvbe = -(g_f + g_f * inv_bf);
        let die_dvbc =  g_r;

        let gmin = Self::GMIN;
        let ic_gmin =  gmin * (vc - vb);
        let ib_gmin =  gmin * (vb - vc) + gmin * (vb - ve);
        let ie_gmin =  gmin * (ve - vb);

        let ic = p * ic_intrinsic + ic_gmin;
        let ib = p * ib_intrinsic + ib_gmin;
        let ie = p * ie_intrinsic + ie_gmin;

        let dic_dvc = -dic_dvbc;
        let dic_dvb =  dic_dvbe + dic_dvbc;
        let dic_dve = -dic_dvbe;
        let dib_dvc = -dib_dvbc;
        let dib_dvb =  dib_dvbe + dib_dvbc;
        let dib_dve = -dib_dvbe;
        let die_dvc = -die_dvbc;
        let die_dvb =  die_dvbe + die_dvbc;
        let die_dve = -die_dvbe;

        DeviceEval {
            g: smallvec![ic, ib, ie],
            q: smallvec![0.0, 0.0, 0.0],
            G: smallvec![
                (0, 0,  dic_dvc + gmin),
                (0, 1,  dic_dvb - gmin),
                (0, 2,  dic_dve),
                (1, 0,  dib_dvc - gmin),
                (1, 1,  dib_dvb + 2.0 * gmin),
                (1, 2,  dib_dve - gmin),
                (2, 0,  die_dvc),
                (2, 1,  die_dvb - gmin),
                (2, 2,  die_dve + gmin),
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
        // If fewer than 6 voltages, internal nodes haven't been wired yet.
        // Fall back to 3-terminal so the circuit still converges.
        if voltages.len() < 6 {
            return self.eval_intrinsic_3pin(voltages, params);
        }

        // External pin voltages (from circuit nodes).
        let vc_ext = voltages[0];
        let vb_ext = voltages[1];
        let ve_ext = voltages[2];
        // Internal pin voltages (internal nodes in MNA).
        let vc_int = voltages[3];
        let vb_int = voltages[4];
        let ve_int = voltages[5];

        // Evaluate the GP core using internal node voltages.
        let core = self.eval_intrinsic_3pin(&[vc_int, vb_int, ve_int], params);

        // Conductances for extrinsic resistors: G = 1/R.
        let gc = if rc > 0.0 { 1.0 / rc } else { 0.0 };
        let gb = if rb > 0.0 { 1.0 / rb } else { 0.0 };
        let ge = if re > 0.0 { 1.0 / re } else { 0.0 };

        // Currents through the extrinsic resistors (flowing from ext to int).
        // i_R = (V_ext - V_int) * G
        let ir_c = (vc_ext - vc_int) * gc;
        let ir_b = (vb_ext - vb_int) * gb;
        let ir_e = (ve_ext - ve_int) * ge;

        // Build combined 6-terminal DeviceEval.
        // Residual currents:
        //   ext_C (pin 0): current = +ir_c (flowing into the node from resistor)
        //   ext_B (pin 1): current = +ir_b
        //   ext_E (pin 2): current = +ir_e
        //   int_C (pin 3): current = core.g[0] - ir_c (GP current minus what flows to ext)
        //   int_B (pin 4): current = core.g[1] - ir_b
        //   int_E (pin 5): current = core.g[2] - ir_e
        //
        // Sign convention matches the stamper: g[pin] is the KCL residual
        // that must sum to zero at convergence.

        // Jacobian: extrinsic resistor conductance entries.
        // Each resistor contributes a 2x2 block: (ext, int) × (ext, int).
        // d(i_R_ext) / d(V_ext) = +G,   d(i_R_ext) / d(V_int) = -G
        // d(i_R_int) / d(V_ext) = -G,   d(i_R_int) / d(V_int) = +G
        //
        // For int_pin currents we also add the GP core Jacobian (re-indexed to pins 3,4,5).
        let mut g6_jac: SmallVec<[(u8, u8, f64); 8]> = SmallVec::new();

        // RC: pins 0 (ext_C) and 3 (int_C)
        if gc > 0.0 {
            g6_jac.push((0, 0,  gc));
            g6_jac.push((0, 3, -gc));
            g6_jac.push((3, 0, -gc));
            g6_jac.push((3, 3,  gc));
        }
        // RB: pins 1 (ext_B) and 4 (int_B)
        if gb > 0.0 {
            g6_jac.push((1, 1,  gb));
            g6_jac.push((1, 4, -gb));
            g6_jac.push((4, 1, -gb));
            g6_jac.push((4, 4,  gb));
        }
        // RE: pins 2 (ext_E) and 5 (int_E)
        if ge > 0.0 {
            g6_jac.push((2, 2,  ge));
            g6_jac.push((2, 5, -ge));
            g6_jac.push((5, 2, -ge));
            g6_jac.push((5, 5,  ge));
        }

        // Append GP core Jacobian re-indexed from (0,1,2) → (3,4,5).
        for (row, col, val) in &core.G {
            g6_jac.push((row + 3, col + 3, *val));
        }

        DeviceEval {
            g: smallvec![
                ir_c,
                ir_b,
                ir_e,
                core.g[0] - ir_c,
                core.g[1] - ir_b,
                core.g[2] - ir_e,
            ],
            q: smallvec![0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            G: g6_jac,
            C: SmallVec::new(),
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
    fn eval_gp(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {

        // ── Parameter extraction ──────────────────────────────────────────────
        let is  = params.get_or("is",  1e-16);  // saturation current
        let bf  = params.get_or("bf",  100.0);  // forward beta
        let nf  = params.get_or("nf",  1.0);    // forward emission coefficient
        let vaf = params.get_or("vaf", 1e30);   // forward Early voltage
        let ikf = params.get_or("ikf", 1e30);   // forward knee current (high-injection)
        let ise = params.get_or("ise", 0.0);    // BE leakage saturation current
        let ne  = params.get_or("ne",  1.5);    // BE leakage emission coefficient
        let br  = params.get_or("br",  1.0);    // reverse beta
        let nr  = params.get_or("nr",  1.0);    // reverse emission coefficient
        let var = params.get_or("var", 1e30);   // reverse Early voltage
        let ikr = params.get_or("ikr", 1e30);   // reverse knee current
        let isc = params.get_or("isc", 0.0);    // BC leakage saturation current
        let nc  = params.get_or("nc",  2.0);    // BC leakage emission coefficient
        // Accept remaining GP parameters (consumed to avoid parse errors).
        let _rb   = params.get_or("rb",   0.0);
        let _irb  = params.get_or("irb",  1e30);
        let _rbm  = params.get_or("rbm",  _rb);
        let _re   = params.get_or("re",   0.0);
        let _rc   = params.get_or("rc",   0.0);
        let _cje  = params.get_or("cje",  0.0);
        let _vje  = params.get_or("vje",  0.75);
        let _mje  = params.get_or("mje",  0.33);
        // Transit-time parameters (active for charge stamping).
        let tf    = params.get_or("tf",   0.0);
        let xtf   = params.get_or("xtf",  0.0);
        let vtf   = params.get_or("vtf",  1e30);
        let itf   = params.get_or("itf",  0.0);
        let ptf   = params.get_or("ptf",  0.0);
        let _cjc  = params.get_or("cjc",  0.0);
        let _vjc  = params.get_or("vjc",  0.75);
        let _mjc  = params.get_or("mjc",  0.33);
        let _xcjc = params.get_or("xcjc", 1.0);
        let _tr   = params.get_or("tr",   0.0);
        // CJS — collector-substrate capacitance (active: stamped between C and ground).
        let cjs   = params.get_or("cjs",  0.0);
        let vjs   = params.get_or("vjs",  0.75);
        let mjs   = params.get_or("mjs",  0.0);
        let xtb   = params.get_or("xtb",  0.0);
        let eg    = params.get_or("eg",   1.11);
        let xti   = params.get_or("xti",  3.0);
        let _kf   = params.get_or("kf",   0.0);
        let _af   = params.get_or("af",   1.0);
        let fc    = params.get_or("fc",   0.5);
        let temp  = params.get_or("temp", 300.15);
        let tnom  = params.get_or("tnom", 300.15);

        // Vt(T) = kT/q; honour explicit "vt" override or derive from temp.
        let vt = if params.contains("vt") {
            params.get_or("vt", Self::DEFAULT_VT)
        } else if params.contains("temp") {
            Self::KB * temp / Self::Q
        } else {
            Self::DEFAULT_VT
        };

        // Temperature-scale Is, Bf, Br, Ise, Isc.
        let is  = Self::temperature_scale_is(is, temp, tnom, xti, eg, nf);
        let bf  = Self::temperature_scale_beta(bf, temp, tnom, xtb);
        let br  = Self::temperature_scale_beta(br, temp, tnom, xtb);
        let ise = if ise > 0.0 { Self::temperature_scale_is(ise, temp, tnom, xti, eg, ne) } else { 0.0 };
        let isc = if isc > 0.0 { Self::temperature_scale_is(isc, temp, tnom, xti, eg, nc) } else { 0.0 };

        // Pre-compute scaled thermal voltages.
        let nf_vt  = nf  * vt;
        let nr_vt  = nr  * vt;
        let ne_vt  = ne  * vt;
        let nc_vt  = nc  * vt;

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
        let inv_bf  = 1.0 / bf;
        let inv_br  = 1.0 / br;

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
        let dqb_dvbe = q1 * q1 * inv_var * (1.0 + sqarg) * 0.5
                     + q1 * g_f * inv_ikf * inv_sqarg;

        // d(qb)/d(vbc):
        let dqb_dvbc = q1 * q1 * inv_vaf * (1.0 + sqarg) * 0.5
                     + q1 * g_r * inv_ikr * inv_sqarg;

        // ── Transport current and its Jacobian contributions ──────────────────
        //
        //   Icc = (If - Ir) / qb
        //
        // d(Icc)/d(vbe) = g_f/qb - (If - Ir)/qb^2 * dqb_dvbe
        //               = g_f * inv_qb - Icc * inv_qb * dqb_dvbe
        //
        // d(Icc)/d(vbc) = -g_r * inv_qb - Icc * inv_qb * dqb_dvbc
        let icc = (i_f - i_r) * inv_qb;
        let dicc_dvbe =  g_f * inv_qb - icc * inv_qb * dqb_dvbe;
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
        let dic_dvbe =  dicc_dvbe;                  // d(Icc)/d(vbe); Ibc no vbe dep
        let dic_dvbc =  dicc_dvbc - dibc_dvbc;      // d(Icc-Ibc)/d(vbc)
        let dib_dvbe =  dibe_dvbe;                  // d(Ibe)/d(vbe); Ibc no vbe dep
        let dib_dvbc =  dibc_dvbc;                  // d(Ibc)/d(vbc); Ibe no vbc dep
        let die_dvbe = -(dicc_dvbe + dibe_dvbe);
        let die_dvbc = -dicc_dvbc;                  // Ibe no vbc dep

        // ── GMIN leakage across junctions (numerical stability) ───────────────
        let gmin = Self::GMIN;
        // Small conductance between B-C and B-E to keep Jacobian non-singular.
        let ic_gmin =  gmin * (vc - vb);   // leakage into collector
        let ib_gmin =  gmin * (vb - vc) + gmin * (vb - ve);
        let ie_gmin =  gmin * (ve - vb);

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
        let dic_dvb =  dic_dvbe + dic_dvbc;
        let dic_dve = -dic_dvbe;

        let dib_dvc = -dib_dvbc;
        let dib_dvb =  dib_dvbe + dib_dvbc;
        let dib_dve = -dib_dvbe;

        let die_dvc = -die_dvbc;
        let die_dvb =  die_dvbe + die_dvbc;
        let die_dve = -die_dvbe;

        // ── Transit-time forward charge Q_F = TF_eff * IC ────────────────────
        //
        // Standard SPICE Gummel-Poon transit-time modulation formula:
        //
        //   TF_eff = TF * (1 + XTF * (Ic/(Ic+ITF))^2 * exp(Vbc/(1.44*VTF)))
        //
        // where XTF, VTF, ITF are bias-dependent transit-time parameters, and
        // PTF is excess phase in degrees applied as a cos(ptf_rad) scale on Q_F.
        //
        // Q_F = TF_eff * IC  (stored in base, appears as base charge)
        //
        // dQ_F/dVbe = TF_eff * dIC/dVbe   (dominant term)
        // dQ_F/dVbc = TF_eff * dIC/dVbc + IC * dTF_eff/dVbc
        //   where d(TF_eff)/d(Vbc) = TF * XTF * itf_sq * exp(Vbc/(1.44*VTF)) / (1.44*VTF)
        //
        // Pin conventions: Q_F charges the base (pin 1) and discharges at the
        // collector side — net effect is +Q_F on base, -Q_F on collector.
        let (q_tf, c_tf_be, c_tf_bc) = if tf > 0.0 && ic_intrinsic > 0.0 {
            // Standard SPICE Gummel-Poon transit-time modulation:
            //   TF_eff = TF * (1 + XTF * (Ic/(Ic+ITF))^2 * exp(Vbc/(1.44*VTF)))
            //
            // XTF scales an exponential in Vbc (excess phase / bias dependence).
            // ITF is the high-injection knee: (Ic/(Ic+ITF))^2 → 0 at low Ic, → 1 at high Ic.
            // Both are combined inside the (1 + ...) bracket per the SPICE standard.
            let itf_sq = if itf > 0.0 {
                let ratio = ic_intrinsic / (ic_intrinsic + itf);
                ratio * ratio
            } else {
                1.0
            };
            let xtf_exp = if xtf != 0.0 && vtf < 1e29 {
                xtf * itf_sq * (vbc / (1.44 * vtf)).exp()
            } else {
                0.0
            };
            let tf_eff = tf * (1.0 + xtf_exp);

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

            let q_f = tf_eff * ic_intrinsic * ptf_scale;

            // C Jacobian w.r.t. Vbe and Vbc (chain-ruled to pins below).
            // dTF_eff/dVbc (only when XTF and VTF active):
            // d(TF_eff)/d(Vbc) = TF * XTF * itf_sq * exp(Vbc/(1.44*VTF)) / (1.44*VTF)
            let dtf_dvbc = if xtf != 0.0 && vtf < 1e29 {
                tf * xtf * itf_sq / (1.44 * vtf) * (vbc / (1.44 * vtf)).exp()
            } else {
                0.0
            };
            // dQ_F/dVbe = TF_eff * ptf_scale * dIC/dVbe
            let dqf_dvbe = tf_eff * ptf_scale * dicc_dvbe;
            // dQ_F/dVbc = TF_eff * ptf_scale * dIC/dVbc + IC * ptf_scale * dTF_eff/dVbc
            let dqf_dvbc = tf_eff * ptf_scale * dicc_dvbc + ic_intrinsic * ptf_scale * dtf_dvbc;

            (q_f, dqf_dvbe, dqf_dvbc)
        } else {
            (0.0, 0.0, 0.0)
        };

        // Chain rule (vbe, vbc) → (Vc, Vb, Ve) for charge Jacobian (same as G above).
        // dQ/dVc = -dQ/dVbc
        // dQ/dVb =  dQ/dVbe + dQ/dVbc
        // dQ/dVe = -dQ/dVbe
        let dqf_dvc = -c_tf_bc;
        let dqf_dvb =  c_tf_be + c_tf_bc;
        let dqf_dve = -c_tf_be;

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
        // Transit-time charge Q_F: net charge flows base (+) and collector (-).
        // CJS charge Q_cs: referenced collector-to-ground (pin 0 relative to ground).

        // Build C Jacobian entries (accumulate tf and cjs contributions).
        let mut cap_entries: SmallVec<[(u8, u8, f64); 8]> = SmallVec::new();
        if q_tf != 0.0 || dqf_dvb != 0.0 || dqf_dvc != 0.0 || dqf_dve != 0.0 {
            // Q_F on base (pin 1) and -Q_F on collector (pin 0).
            // C[row][col] = dQ_row/dV_col.
            // Base row charges: dQ_base/dVb, dQ_base/dVc, dQ_base/dVe
            if dqf_dvb != 0.0 { cap_entries.push((1, 1,  dqf_dvb)); }
            if dqf_dvc != 0.0 { cap_entries.push((1, 0,  dqf_dvc)); }
            if dqf_dve != 0.0 { cap_entries.push((1, 2,  dqf_dve)); }
            // Collector row: -Q_F so signs flip.
            if dqf_dvb != 0.0 { cap_entries.push((0, 1, -dqf_dvb)); }
            if dqf_dvc != 0.0 { cap_entries.push((0, 0, -dqf_dvc)); }
            if dqf_dve != 0.0 { cap_entries.push((0, 2, -dqf_dve)); }
        }
        if c_cjs != 0.0 {
            // CJS between collector (pin 0) and ground:
            // dQ_c/dVc = +c_cjs  (only diagonal; ground row not tracked in 3-pin MNA)
            cap_entries.push((0, 0, c_cjs));
        }

        DeviceEval {
            g: smallvec![ic, ib, ie],
            q: smallvec![
                ic_intrinsic * 0.0 - q_tf + q_cjs,  // collector: -Q_F (transit) + Q_cs (cjs)
                q_tf,                                  // base: +Q_F (transit time charge)
                0.0,                                   // emitter: no charge in 3-pin GP
            ],
            G: smallvec![
                // Collector row (pin 0)
                (0, 0,  dic_dvc + gmin),
                (0, 1,  dic_dvb - gmin),
                (0, 2,  dic_dve),
                // Base row (pin 1)
                (1, 0,  dib_dvc - gmin),
                (1, 1,  dib_dvb + 2.0 * gmin),
                (1, 2,  dib_dve - gmin),
                // Emitter row (pin 2)
                (2, 0,  die_dvc),
                (2, 1,  die_dvb - gmin),
                (2, 2,  die_dve + gmin),
            ],
            C: cap_entries,
            rhs: SmallVec::new(),
        }
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
        p.set("is",  1e-16);
        p.set("bf",  100.0);
        p.set("nf",  1.0);
        p.set("br",  1.0);
        p.set("nr",  1.0);
        p.set("vt",  0.02585);
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
                let analytic = e0.G.iter()
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
        let analytic = e0.G.iter()
            .find(|(r, c, _)| *r == 0 && *c == 1)
            .map(|(_, _, v)| *v)
            .unwrap();
        assert!(
            (fd - analytic).abs() / analytic.abs().max(1e-20) < 1e-2,
            "NPN FD d(Ic)/d(Vb): fd={} analytic={}",
            fd, analytic
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
        let go_analytic = eval_mid.G.iter()
            .find(|(r, c, _)| *r == 0 && *c == 0)
            .map(|(_, _, v)| *v)
            .unwrap_or(0.0);

        let ic_mid = eval_mid.g[0];
        let go_expected = ic_mid / 50.0;  // ≈ Ic / Vaf
        // Allow factor-of-3 tolerance (qb makes it slightly different from raw Ic/Vaf).
        assert!(
            (go_analytic - go_expected).abs() / go_expected.abs().max(1e-30) < 3.0,
            "go_analytic={} go_expected={} Ic_mid={}",
            go_analytic, go_expected, ic_mid
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
        p.set("ikf", 1e-3);  // low knee so high-injection kicks in at moderate Ic

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
        assert!(max_err < 5e-2, "high-injection Jacobian FD error: {max_err}");
    }

    /// Recombination current: with Ise=1e-13, Ne=2 at low Vbe=0.5,
    /// the base current is dominated by recombination so Ic/Ib < Bf.
    #[test]
    fn bjt_recombination() {
        let q = Bjt::npn();
        let mut p = npn_params();
        p.set("ise", 1e-13);
        p.set("ne",  2.0);

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
            [5.0, 0.7, 0.0],   // forward active
            [0.2, 0.7, 0.0],   // saturation
            [0.0, 0.7, 1.2],   // reverse active
            [0.0, 0.0, 0.0],   // cutoff
            [5.0, 0.85, 0.0],  // high injection
        ];

        for v in test_points {
            let eval = q.eval(v, &params);
            let kcl = eval.g[0] + eval.g[1] + eval.g[2];
            assert!(
                kcl.abs() < 1e-6,
                "KCL failed at {:?}: Ic={} Ib={} Ie={} sum={}",
                v, eval.g[0], eval.g[1], eval.g[2], kcl
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
        p.set("is",    1e-16);
        p.set("bf",    100.0);
        p.set("nf",    1.0);
        p.set("vaf",   100.0);
        p.set("ikf",   0.1);
        p.set("ise",   1e-14);
        p.set("ne",    1.5);
        p.set("br",    2.0);
        p.set("nr",    1.0);
        p.set("var",   20.0);
        p.set("ikr",   0.01);
        p.set("isc",   1e-14);
        p.set("nc",    2.0);
        // Resistances
        p.set("rb",    100.0);
        p.set("irb",   0.001);
        p.set("rbm",   10.0);
        p.set("re",    1.0);
        p.set("rc",    10.0);
        // Capacitance / transit
        p.set("cje",   1e-12);
        p.set("vje",   0.75);
        p.set("mje",   0.33);
        p.set("tf",    4e-11);
        p.set("xtf",   2.0);
        p.set("vtf",   1.7);
        p.set("itf",   0.6);
        p.set("ptf",   0.0);
        p.set("cjc",   5e-13);
        p.set("vjc",   0.75);
        p.set("mjc",   0.33);
        p.set("xcjc",  0.9);
        p.set("tr",    5e-10);
        p.set("cjs",   2e-12);
        p.set("vjs",   0.75);
        p.set("mjs",   0.0);
        // Temperature / noise
        p.set("xtb",   1.5);
        p.set("eg",    1.11);
        p.set("xti",   3.0);
        p.set("kf",    0.0);
        p.set("af",    1.0);
        p.set("fc",    0.5);
        p.set("vt",    0.02585);
        p.set("tnom",  300.15);
        p.set("level", 1.0);

        // Should produce finite currents without panic.
        let eval = q.eval(&[5.0, 0.7, 0.0], &p);
        assert!(eval.g[0].is_finite());
        assert!(eval.g[1].is_finite());
        assert!(eval.g[2].is_finite());
        let kcl = eval.g[0] + eval.g[1] + eval.g[2];
        assert!(kcl.abs() < 1e-6, "full-params KCL: {kcl}");
    }
}
