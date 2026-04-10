use smallvec::{SmallVec, smallvec};
use pisim_core::{DeviceKind, ParamMap};

use crate::eval::{DeviceEval, DeviceModel};

/// VBIC (Vertical Bipolar Inter-Company) BJT model — DC transport cut.
///
/// Pin layout (4 terminals):
///   Pin 0 = collector (C)
///   Pin 1 = base (B)
///   Pin 2 = emitter (E)
///   Pin 3 = substrate (S) — treated as external node; DC stamp ignores substrate
///           currents in this first cut (substrate BJT left for future wave).
///
/// For NPN: junction voltages Vbe = Vb - Ve, Vbc = Vb - Vc.
/// For PNP: voltages are flipped (polarity = -1) so the same equations apply.
///
/// # VBIC DC transport equations (intrinsic transistor, no avalanche)
///
/// Forward and reverse injection (VBIC uses separate Is for F/R paths):
///   Ibe  = ibei * (exp(Vbe / (nei * Vt)) - 1)   — ideal BE current
///   Iben = iben * (exp(Vbe / (nen * Vt)) - 1)   — non-ideal BE leakage
///   Ibc  = ibci * (exp(Vbc / (nci * Vt)) - 1)   — ideal BC current
///   Ibcn = ibcn * (exp(Vbc / (ncn * Vt)) - 1)   — non-ideal BC leakage
///
/// Excess phase / parasitic B currents (substrate path simplified to zero DC):
///   Ibex = ibeip * (exp(Vbex / (nei * Vt)) - 1)  — parallel BE (wbe path)
///
/// Transport current (VBIC uses qb for base charge modulation):
///   q1 = 1 / (1 - Vbc/Vef - Vbe/Ver)            — Early factor
///   q2 = If/Ikf + Ir/Ikr                          — Webster factor
///   qb = (q1/2) * (1 + sqrt(1 + 4*q2))
///   If = is  * (exp(Vbe / (nf * Vt)) - 1)        — forward transport
///   Ir = is  * (exp(Vbc / (nr * Vt)) - 1)        — reverse transport
///   Icc = (If - Ir) / qb                           — intrinsic collector transport
///
/// Terminal currents:
///   Ic = Icc - Ibc - Ibcn                         — collector (intrinsic)
///   Ib = Ibe + Iben + Ibc + Ibcn                  — base
///   Ie = -(Icc + Ibe + Iben)                       — emitter
///   Is = 0 (substrate DC contribution deferred)
///
/// # Parameters supported (DC-critical subset)
///
/// Transport: `is`, `nf`, `nr`, `vef`, `ver`, `ikf`, `ikr`
/// Base current: `ibei`, `nei`, `iben`, `nen`, `ibci`, `nci`, `ibcn`, `ncn`
/// Parallel emitter: `ibeip`, `wbe` (fraction of Ibe through external Rb)
/// Resistances (accepted/ignored in DC-only cut): `rcx`, `rci`, `rbx`, `rbi`, `re`, `rs`, `rbp`
/// Transit time (accepted/ignored): `tf`, `qtf`, `xtf`, `vtf`, `itf`, `tr`, `td`
/// Avalanche (active): `avc1`, `avc2`, `pc` (BC built-in potential), `mc` (BC grading)
/// Substrate (active): `isp`, `wsp`, `nfp`, `ibcip`, `ncip`, `ibcnp`, `ncnp`
/// Capacitances (deferred): `cbeo`, `cbco`, `fc`
///
/// # Weak avalanche multiplication
///
/// VBIC95 weak avalanche current at the BC junction:
///
///   `vl  = (pc - vbcj).max(eps)`              (clamped reverse voltage)
///   `Iavl = (Itzf + Ibcj) * Avc1 * vl * exp(-Avc2 * vl^MC)`
///
/// where `Itzf` is the forward transport current and `Ibcj` is the BC junction
/// current. `Iavl` flows from collector to base (multiplication injects extra
/// holes into the base for an NPN). Stamped as `+Iavl` on the collector and
/// `-Iavl` on the base terminal.
///
/// # Parasitic substrate PNP/NPN
///
/// VBIC includes a parasitic vertical PNP (for NPN main device) sitting between
/// the collector and the substrate, with the BC of the main device as its emitter
/// and the substrate as its collector. The parasitic transport current is:
///
///   `Itsf = isp * (exp(Vbcj/(nfp*Vt)) - 1)`
///   `Iccp = Itsf / qbp`           (parasitic transport)
///   `Ibcp = ibcip * (exp(Vbcp/(ncip*Vt)) - 1)`     (parasitic BC junction)
///   `Ibcnp = ibcnp * (exp(Vbcp/(ncnp*Vt)) - 1)`    (parasitic BC non-ideal)
///
/// where `Vbcp = Vb - Vs`. The parasitic currents are added to the
/// collector / substrate / base terminal currents accordingly.
///
/// # Self-heating thermal node (pin 4)
///
/// When `rth > 0`, a thermal node is added as pin 4. Its voltage represents
/// the temperature rise ΔT above nominal:
///
///   Rth (thermal resistance, K/W): conductance Gth = 1/Rth stamps pin 4 to ground.
///   Cth (thermal capacitance, J/K): capacitive stamp on pin 4 (transient).
///   P_diss = Vce * Ic + Vbe * Ib: power dissipation current source into pin 4.
///   T_junction = Tnom + V_thermal (temperature feedback — deferred to future wave).
///
/// Parameters: `rth` (default 0 = disabled), `cth` (default 0).
///
/// TODO: extrinsic resistances (rcx, rci, rbx, rbi, re, rs, rbp) — internal node expansion.
/// TODO: transit-time junction charges (tf, qtf, xtf, vtf, itf, tr, td, cbeo, cbco) for transient.
#[derive(Debug, Clone, Copy)]
pub struct Vbic {
    /// +1.0 for NPN, -1.0 for PNP.
    pub polarity: f64,
    /// When true, a 5th thermal node (pin 4 = ΔT) is active.
    /// Set this based on whether `rth > 0` in the model card.
    pub thermal: bool,
}

impl Vbic {
    pub const fn npn() -> Self {
        Self { polarity: 1.0, thermal: false }
    }

    pub const fn pnp() -> Self {
        Self { polarity: -1.0, thermal: false }
    }

    /// Construct an NPN with thermal node enabled (for circuits that set rth > 0).
    pub const fn npn_thermal() -> Self {
        Self { polarity: 1.0, thermal: true }
    }

    /// Construct a PNP with thermal node enabled.
    pub const fn pnp_thermal() -> Self {
        Self { polarity: -1.0, thermal: true }
    }

    /// Default thermal voltage at ~300 K.
    const DEFAULT_VT: f64 = 0.02585;
    /// Per-junction GMIN for numerical stability.
    const GMIN: f64 = 1e-12;

    /// Compute junction current and conductance with SPICE voltage limiting.
    ///
    /// Uses the same linearized tangent clamping as the GP BJT model so Newton
    /// steps remain well-conditioned at extreme forward bias.
    #[inline]
    fn exp_iv(v: f64, is: f64, nvt: f64) -> (f64, f64) {
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

    /// Stamp extrinsic series resistances for VBIC as conductance entries between
    /// external pins (0=C, 1=B, 2=E, 3=S) and internal pins (4=C', 5=B', 6=E', 7=S').
    ///
    /// The 7 VBIC resistors are reduced to 4 lumped resistors for the DC-only cut:
    ///   rc_lump = rcx + rci   (collector path)
    ///   rb_lump = rbx + rbi + rbp  (base path, rbp = parasitic base resistance)
    ///   re_lump = re           (emitter path)
    ///   rs_lump = rs           (substrate path)
    ///
    /// Returns an 8-terminal DeviceEval. Falls back to 4-terminal eval when
    /// `voltages.len() < 8` (i.e., internal nodes not yet wired by the circuit builder).
    fn eval_with_extrinsic(
        &self,
        voltages: &[f64],
        params: &ParamMap,
        rc_lump: f64,
        rb_lump: f64,
        re_lump: f64,
        rs_lump: f64,
    ) -> DeviceEval {
        if voltages.len() < 8 {
            return self.eval_intrinsic_4pin(voltages, params);
        }

        // External pins: C=0, B=1, E=2, S=3
        let vc_ext = voltages[0];
        let vb_ext = voltages[1];
        let ve_ext = voltages[2];
        let vs_ext = voltages[3];
        // Internal pins: C'=4, B'=5, E'=6, S'=7
        let vc_int = voltages[4];
        let vb_int = voltages[5];
        let ve_int = voltages[6];
        let vs_int = voltages[7];

        // Evaluate the VBIC intrinsic core using internal node voltages.
        let core = self.eval_intrinsic_4pin(&[vc_int, vb_int, ve_int, vs_int], params);

        // Conductances for lumped extrinsic resistors.
        let gc = if rc_lump > 0.0 { 1.0 / rc_lump } else { 0.0 };
        let gb = if rb_lump > 0.0 { 1.0 / rb_lump } else { 0.0 };
        let ge = if re_lump > 0.0 { 1.0 / re_lump } else { 0.0 };
        let gs = if rs_lump > 0.0 { 1.0 / rs_lump } else { 0.0 };

        // Currents through resistors (ext → int direction).
        let ir_c = (vc_ext - vc_int) * gc;
        let ir_b = (vb_ext - vb_int) * gb;
        let ir_e = (ve_ext - ve_int) * ge;
        let ir_s = (vs_ext - vs_int) * gs;

        // Build Jacobian for 8-terminal stamp.
        let mut jac: SmallVec<[(u8, u8, f64); 8]> = SmallVec::new();

        // RC: pins 0 (ext_C) and 4 (int_C)
        if gc > 0.0 {
            jac.push((0, 0,  gc));
            jac.push((0, 4, -gc));
            jac.push((4, 0, -gc));
            jac.push((4, 4,  gc));
        }
        // RB: pins 1 (ext_B) and 5 (int_B)
        if gb > 0.0 {
            jac.push((1, 1,  gb));
            jac.push((1, 5, -gb));
            jac.push((5, 1, -gb));
            jac.push((5, 5,  gb));
        }
        // RE: pins 2 (ext_E) and 6 (int_E)
        if ge > 0.0 {
            jac.push((2, 2,  ge));
            jac.push((2, 6, -ge));
            jac.push((6, 2, -ge));
            jac.push((6, 6,  ge));
        }
        // RS: pins 3 (ext_S) and 7 (int_S)
        if gs > 0.0 {
            jac.push((3, 3,  gs));
            jac.push((3, 7, -gs));
            jac.push((7, 3, -gs));
            jac.push((7, 7,  gs));
        }

        // Append intrinsic core Jacobian re-indexed from pins (0,1,2,3) → (4,5,6,7).
        for (row, col, val) in &core.G {
            jac.push((row + 4, col + 4, *val));
        }

        DeviceEval {
            g: smallvec![
                ir_c,
                ir_b,
                ir_e,
                ir_s,
                core.g[0] - ir_c,
                core.g[1] - ir_b,
                core.g[2] - ir_e,
                core.g[3] - ir_s,
            ],
            q: smallvec![0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            G: jac,
            C: SmallVec::new(),
            rhs: SmallVec::new(),
        }
    }

    /// 4-terminal intrinsic VBIC evaluation (no extrinsic resistances).
    fn eval_intrinsic_4pin(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        self.eval_core(voltages, params)
    }
}

impl DeviceModel for Vbic {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let rcx = params.get_or("rcx", 0.0);
        let rci = params.get_or("rci", 0.0);
        let rbx = params.get_or("rbx", 0.0);
        let rbi = params.get_or("rbi", 0.0);
        let re  = params.get_or("re",  0.0);
        let rs  = params.get_or("rs",  0.0);
        let rbp = params.get_or("rbp", 0.0);

        let rc_lump = rcx + rci;
        let rb_lump = rbx + rbi + rbp;
        let re_lump = re;
        let rs_lump = rs;

        if rc_lump > 0.0 || rb_lump > 0.0 || re_lump > 0.0 || rs_lump > 0.0 {
            return self.eval_with_extrinsic(voltages, params, rc_lump, rb_lump, re_lump, rs_lump);
        }
        self.eval_core(voltages, params)
    }

    fn num_terminals(&self) -> usize {
        if self.thermal { 5 } else { 4 }
    }

    fn kind(&self) -> DeviceKind {
        if self.polarity > 0.0 {
            DeviceKind::VbicNpn
        } else {
            DeviceKind::VbicPnp
        }
    }
}

impl Vbic {
    fn eval_core(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        // ── Parameter extraction ──────────────────────────────────────────────
        // Core transport (VBIC notation)
        let is   = params.get_or("is",   1e-16); // transport saturation current
        let nf   = params.get_or("nf",   1.0);   // forward emission coefficient
        let nr   = params.get_or("nr",   1.0);   // reverse emission coefficient
        let vef  = params.get_or("vef",  1e30);  // forward Early voltage
        let ver  = params.get_or("ver",  1e30);  // reverse Early voltage
        let ikf  = params.get_or("ikf",  1e30);  // forward knee current
        let ikr  = params.get_or("ikr",  1e30);  // reverse knee current
        let vt   = params.get_or("vt",   Self::DEFAULT_VT);

        // Base current parameters
        let ibei = params.get_or("ibei", 1e-18); // ideal BE saturation current
        let nei  = params.get_or("nei",  1.0);   // ideal BE emission coefficient
        let iben = params.get_or("iben", 0.0);   // non-ideal BE saturation current
        let nen  = params.get_or("nen",  2.0);   // non-ideal BE emission coefficient
        let ibci = params.get_or("ibci", 1e-17); // ideal BC saturation current
        let nci  = params.get_or("nci",  1.0);   // ideal BC emission coefficient
        let ibcn = params.get_or("ibcn", 0.0);   // non-ideal BC saturation current
        let ncn  = params.get_or("ncn",  2.0);   // non-ideal BC emission coefficient

        // Extrinsic base current (WBE fraction)
        let ibeip = params.get_or("ibeip", 0.0); // parallel ideal BE current
        let wbe   = params.get_or("wbe",   1.0); // fraction of Ibe through Rbi

        // Accept-and-ignore resistances (DC-only cut — no internal node expansion).
        let _rcx = params.get_or("rcx", 0.0);
        let _rci = params.get_or("rci", 0.0);
        let _rbx = params.get_or("rbx", 0.0);
        let _rbi = params.get_or("rbi", 0.0);
        let _re  = params.get_or("re",  0.0);
        let _rs  = params.get_or("rs",  0.0);
        let _rbp = params.get_or("rbp", 0.0);

        // Accept-and-ignore transit time / capacitance params (deferred).
        let _tf   = params.get_or("tf",   0.0);
        let _qtf  = params.get_or("qtf",  0.0);
        let _xtf  = params.get_or("xtf",  0.0);
        let _vtf  = params.get_or("vtf",  1e30);
        let _itf  = params.get_or("itf",  0.0);
        let _tr   = params.get_or("tr",   0.0);
        let _td   = params.get_or("td",   0.0);
        let _cbeo = params.get_or("cbeo", 0.0);
        let _cbco = params.get_or("cbco", 0.0);
        let _fc   = params.get_or("fc",   0.5);

        // Self-heating thermal node parameters.
        let rth   = params.get_or("rth",  0.0); // thermal resistance (K/W)
        let cth   = params.get_or("cth",  0.0); // thermal capacitance (J/K)

        // Avalanche multiplication parameters (active).
        let avc1 = params.get_or("avc1", 0.0);   // 1st avalanche coefficient
        let avc2 = params.get_or("avc2", 0.0);   // 2nd avalanche coefficient
        let pc   = params.get_or("pc",   0.75);  // BC built-in potential
        let mc   = params.get_or("mc",   0.33);  // BC junction grading exponent

        // Parasitic substrate BJT parameters (active).
        let isp   = params.get_or("isp",   0.0);  // parasitic transport saturation
        let _wsp  = params.get_or("wsp",   1.0);  // parasitic weighting (unused in lumped model)
        let nfp   = params.get_or("nfp",   1.0);  // parasitic forward emission
        let ibcip = params.get_or("ibcip", 0.0);  // parasitic ideal substrate junction
        let ncip  = params.get_or("ncip",  1.0);  // parasitic ideal substrate emission
        let ibcnp = params.get_or("ibcnp", 0.0);  // parasitic non-ideal substrate junction
        let ncnp  = params.get_or("ncnp",  2.0);  // parasitic non-ideal substrate emission
        let _ibenp = params.get_or("ibenp", 0.0); // accepted/ignored (parasitic emitter)

        let p = self.polarity;

        // ── Junction voltages ──────────────────────────────────────────────────
        let vc = voltages[0];
        let vb = voltages[1];
        let ve = voltages[2];
        let vs = voltages[3];

        let vbe = p * (vb - ve);
        let vbc = p * (vb - vc);
        // Parasitic substrate junction voltage:
        //   For NPN main: parasitic BJT is PNP whose base = main collector,
        //   emitter = main base, collector = substrate. Here we use the
        //   simpler lumped form Vbcp = Vb - Vs (substrate junction at base).
        let vbcp = p * (vb - vs);

        // ── Transport currents (VBIC intrinsic: same as GP but with VBIC Early) ─
        let nf_vt = nf * vt;
        let nr_vt = nr * vt;

        let (i_f, g_f) = Self::exp_iv(vbe, is, nf_vt);
        let (i_r, g_r) = Self::exp_iv(vbc, is, nr_vt);

        // Base charge factor qb (VBIC uses Vef/Ver instead of Vaf/Var)
        let inv_vef = 1.0 / vef;
        let inv_ver = 1.0 / ver;
        let inv_ikf = 1.0 / ikf;
        let inv_ikr = 1.0 / ikr;

        let q1_denom = 1.0 - vbc * inv_vef - vbe * inv_ver;
        let q1 = 1.0 / q1_denom.max(1e-10);
        let q2 = i_f * inv_ikf + i_r * inv_ikr;
        let arg = (1.0 + 4.0 * q2).max(0.0);
        let sqarg = arg.sqrt();
        let qb = q1 * (1.0 + sqarg) * 0.5;
        let inv_qb = 1.0 / qb.max(1e-30);
        let inv_sqarg = if sqarg > 1e-30 { 1.0 / sqarg } else { 0.0 };

        let dqb_dvbe = q1 * q1 * inv_ver * (1.0 + sqarg) * 0.5
                     + q1 * g_f * inv_ikf * inv_sqarg;
        let dqb_dvbc = q1 * q1 * inv_vef * (1.0 + sqarg) * 0.5
                     + q1 * g_r * inv_ikr * inv_sqarg;

        // Transport current and Jacobian
        let icc = (i_f - i_r) * inv_qb;
        let dicc_dvbe =  g_f * inv_qb - icc * inv_qb * dqb_dvbe;
        let dicc_dvbc = -g_r * inv_qb - icc * inv_qb * dqb_dvbc;

        // ── Base currents (VBIC has separate ibei/iben instead of GP's is/bf) ──
        let nei_vt = nei * vt;
        let nen_vt = nen * vt;
        let nci_vt = nci * vt;
        let ncn_vt = ncn * vt;

        // Ideal BE: Ibe = (1 - wbe) * Ibei_total
        //   The wbe fraction flows through rbi (internal) and (1-wbe) through rbx (external).
        //   In the DC-only (no internal nodes) cut, we lump both into a single terminal current.
        let ibe_scale = 1.0 - wbe + wbe; // = 1.0; both halves appear at B terminal
        let (ibe_ideal, gbe_ideal) = Self::exp_iv(vbe, ibei * ibe_scale, nei_vt);

        // Non-ideal BE leakage
        let (ibe_nl, gbe_nl) = if iben > 0.0 {
            Self::exp_iv(vbe, iben, nen_vt)
        } else {
            (0.0, 0.0)
        };

        // Parallel BE (ibeip handles the xbeip fraction — simplified to a single terminal current)
        let (ibe_par, gbe_par) = if ibeip > 0.0 {
            Self::exp_iv(vbe, ibeip, nei_vt)
        } else {
            (0.0, 0.0)
        };

        // Ideal BC: Ibc = ibci * (exp(Vbc/(nci*Vt)) - 1)
        let (ibc_ideal, gbc_ideal) = Self::exp_iv(vbc, ibci, nci_vt);

        // Non-ideal BC leakage
        let (ibc_nl, gbc_nl) = if ibcn > 0.0 {
            Self::exp_iv(vbc, ibcn, ncn_vt)
        } else {
            (0.0, 0.0)
        };

        // Total base-emitter and base-collector currents
        let ibe_total = ibe_ideal + ibe_nl + ibe_par;
        let ibc_total = ibc_ideal + ibc_nl;
        let gbe_total = gbe_ideal + gbe_nl + gbe_par;
        let gbc_total = gbc_ideal + gbc_nl;

        // ── Weak avalanche multiplication current ──────────────────────────────
        //
        //   vl  = max(pc - vbc, eps)
        //   x   = avc2 * vl^mc
        //   Iavl = (Itzf + Ibcj) * avc1 * vl * exp(-x)
        //
        // where Itzf = (i_f - i_r) — the bare transport current before qb
        // division — and Ibcj = ibc_ideal here. Iavl flows from collector
        // to base: +Iavl on collector, −Iavl on base.
        //
        // d/dvbc:
        //   dvl/dvbc = -1
        //   dx/dvbc = avc2 * mc * vl^(mc-1) * dvl/dvbc = -avc2*mc*vl^(mc-1)
        //   d(vl*exp(-x))/dvbc = exp(-x)*(dvl/dvbc - vl*dx/dvbc)
        //                      = exp(-x)*(-1 + vl*avc2*mc*vl^(mc-1))
        //                      = exp(-x)*(-1 + avc2*mc*vl^mc)
        //
        // For the d(Itzf+Ibcj)/dvbc term we have d(i_f-i_r)/dvbc = -g_r and
        // d(ibc_ideal)/dvbc = gbc_ideal. We treat (Itzf+Ibcj) as a slowly
        // varying multiplier and only use the dominant g_r contribution
        // (this is the same simplification ngspice's bjt2 takes).
        let (iavl, davl_dvbe, davl_dvbc) = if avc1 > 0.0 {
            let vl_raw = pc - vbc;
            // Smooth clamp at small positive vl so the derivative is well-defined.
            let vl = vl_raw.max(1e-6);
            // dvl/dvbc = -1 only when vl_raw > 1e-6 (otherwise clamped → 0)
            let dvl_dvbc = if vl_raw > 1e-6 { -1.0 } else { 0.0 };
            let mc_eff = mc.max(1e-3);
            let vlm = vl.powf(mc_eff);
            let x = (avc2 * vlm).min(40.0); // clamp exp argument
            let ex = (-x).exp();
            let itzf = i_f - i_r;
            let mult = itzf + ibc_ideal;
            let factor = vl * ex;
            let iavl = mult * avc1 * factor;

            // d(vl*ex)/dvbc = ex*dvl/dvbc + vl*ex*(-dx/dvbc)
            //   where dx/dvbc = avc2 * mc_eff * vl^(mc_eff-1) * dvl/dvbc
            //                 = avc2 * mc_eff * vlm/vl * dvl/dvbc
            // So d(vl*ex)/dvbc = ex*dvl/dvbc - vl*ex*avc2*mc_eff*(vlm/vl)*dvl/dvbc
            //                  = ex*dvl/dvbc * (1 - avc2*mc_eff*vlm)
            let dfactor_dvbc = ex * dvl_dvbc * (1.0 - avc2 * mc_eff * vlm);

            // d(iavl)/dvbe = (g_f) * avc1 * factor
            let davl_dvbe = g_f * avc1 * factor;
            // d(iavl)/dvbc = (-g_r + gbc_ideal) * avc1 * factor + mult * avc1 * dfactor_dvbc
            let dmult_dvbc = -g_r + gbc_ideal;
            let davl_dvbc = dmult_dvbc * avc1 * factor + mult * avc1 * dfactor_dvbc;
            (iavl, davl_dvbe, davl_dvbc)
        } else {
            (0.0, 0.0, 0.0)
        };

        // ── Parasitic substrate BJT (lumped DC) ────────────────────────────────
        //
        //   Itzfp = isp * (exp(vbcp/(nfp*Vt)) - 1)         (parasitic transport)
        //   Ibcip = ibcip * (exp(vbcp/(ncip*Vt)) - 1)      (parasitic ideal junction)
        //   Ibcnp = ibcnp * (exp(vbcp/(ncnp*Vt)) - 1)      (parasitic non-ideal)
        //
        // The parasitic transport current Itzfp flows base→substrate
        // (for an NPN main, the parasitic is PNP so emitter->collector).
        // Combined effect on terminal currents (at base / substrate) is
        // a substrate-direction current that subtracts from base.
        let (i_subs_total, gp_dvbcp) = if isp > 0.0 || ibcip > 0.0 || ibcnp > 0.0 {
            let nfp_vt = nfp * vt;
            let ncip_vt = ncip * vt;
            let ncnp_vt = ncnp * vt;

            let (itzfp, gtzfp) = if isp > 0.0 {
                Self::exp_iv(vbcp, isp, nfp_vt)
            } else { (0.0, 0.0) };
            let (ibcip_i, gbcip) = if ibcip > 0.0 {
                Self::exp_iv(vbcp, ibcip, ncip_vt)
            } else { (0.0, 0.0) };
            let (ibcnp_i, gbcnp) = if ibcnp > 0.0 {
                Self::exp_iv(vbcp, ibcnp, ncnp_vt)
            } else { (0.0, 0.0) };

            let i_total = itzfp + ibcip_i + ibcnp_i;
            let g_total = gtzfp + gbcip + gbcnp;
            (i_total, g_total)
        } else {
            (0.0, 0.0)
        };

        // ── Intrinsic terminal currents (with avalanche + substrate) ───────────
        //   Ic = Icc - Ibc + Iavl
        //   Ib = Ibe + Ibc - Iavl + I_subs   (substrate current sourced by base)
        //   Ie = -(Icc + Ibe)
        //   Is = -I_subs                     (substrate sinks I_subs)
        let ic_intrinsic = icc - ibc_total + iavl;
        let ib_intrinsic = ibe_total + ibc_total - iavl + i_subs_total;
        let ie_intrinsic = -(icc + ibe_total);
        let is_intrinsic = -i_subs_total;

        // Jacobian w.r.t. junction voltages (vbe, vbc) and parasitic vbcp.
        let dic_dvbe =  dicc_dvbe + davl_dvbe;
        let dic_dvbc =  dicc_dvbc - gbc_total + davl_dvbc;
        let dib_dvbe =  gbe_total - davl_dvbe;
        let dib_dvbc =  gbc_total - davl_dvbc;
        let die_dvbe = -(dicc_dvbe + gbe_total);
        let die_dvbc = -dicc_dvbc;
        // Parasitic substrate Jacobian: only depends on vbcp = vb - vs.
        let dis_dvbcp = -gp_dvbcp; // is = -i_subs, di_subs/dvbcp = gp
        let dib_dvbcp =  gp_dvbcp;

        // ── GMIN stability ─────────────────────────────────────────────────────
        let gmin = Self::GMIN;
        let ic_gmin =  gmin * (vc - vb);
        let ib_gmin =  gmin * (vb - vc) + gmin * (vb - ve);
        let ie_gmin =  gmin * (ve - vb);
        let is_gmin =  gmin * (vs - vb);
        let ib_gmin_s = gmin * (vb - vs); // additional base→substrate gmin

        let ic = p * ic_intrinsic + ic_gmin;
        let ib = p * ib_intrinsic + ib_gmin + ib_gmin_s;
        let ie = p * ie_intrinsic + ie_gmin;
        let is_dc = p * is_intrinsic + is_gmin;

        // ── Chain rule: (vbe, vbc, vbcp) → (Vc, Vb, Ve, Vs) ───────────────────
        // d(.)/dvbe = +d(.)/dvb, -d(.)/dve
        // d(.)/dvbc = +d(.)/dvb, -d(.)/dvc
        // d(.)/dvbcp = +d(.)/dvb, -d(.)/dvs
        let dic_dvc = -dic_dvbc;
        let dic_dvb =  dic_dvbe + dic_dvbc;
        let dic_dve = -dic_dvbe;

        let dib_dvc = -dib_dvbc;
        let dib_dvb =  dib_dvbe + dib_dvbc + dib_dvbcp;
        let dib_dve = -dib_dvbe;
        let dib_dvs = -dib_dvbcp;

        let die_dvc = -die_dvbc;
        let die_dvb =  die_dvbe + die_dvbc;
        let die_dve = -die_dvbe;

        let dis_dvb =  dis_dvbcp;
        let dis_dvs = -dis_dvbcp;

        // ── Self-heating thermal node (pin 4) ─────────────────────────────────
        //
        // When rth > 0 a 5th terminal is stamped representing temperature rise ΔT.
        //
        // Thermal conductance Gth = 1/Rth: stamps (4,4, Gth) — thermal node to ground.
        //
        // Power dissipation P_diss = Vce*Ic + Vbe*Ib flows INTO the thermal node as
        // a current source. At steady state V_thermal = P_diss * Rth.
        //
        // We model P_diss as a nonlinear current source on pin 4 with its Jacobian.
        //   P_diss = (Vc - Ve)*Ic + (Vb - Ve)*Ib
        //
        // dP/dVc = Ic  + (Vc-Ve)*dIc/dVc + (Vb-Ve)*dIb/dVc   (full Newton Jacobian)
        // For the first-pass stamp we use the current-source only (no lin-feedback into
        // junctions from ΔT — temperature feedback is deferred to a future wave).
        //
        // Thermal capacitance Cth: stamps (4,4, Cth) in the C Jacobian for transient.
        if rth > 0.0 {
            let gth = 1.0 / rth;

            // Power dissipation: P = (Vc-Ve)*Ic + (Vb-Ve)*Ib
            let vce = vc - ve;
            let vbe_term = vb - ve;
            let p_diss = vce * p * ic_intrinsic + vbe_term * p * ib_intrinsic;

            // Jacobian of P_diss w.r.t. node voltages (chain rule, polarity p already applied).
            let dp_dvc =  p * ic_intrinsic + vce * p * dic_dvbc * (-p);  // d(Vce)/dVc * Ic + Vce * dIc/dVc
            let dp_dvc_exact = p * ic_intrinsic + vce * dic_dvc + vbe_term * dib_dvc;
            let dp_dvb  = vce * dic_dvb + p * 0.0 + vbe_term * dib_dvb + p * ib_intrinsic;
            let dp_dve  = -p * ic_intrinsic + vce * dic_dve - p * ib_intrinsic + vbe_term * dib_dve;
            let _ = dp_dvc; // suppress unused warning; we use the exact version below

            // ── Assemble DeviceEval (5 terminals: C=0, B=1, E=2, S=3, T=4) ─────
            let mut g5 = SmallVec::<[f64; 8]>::new();
            g5.push(ic);
            g5.push(ib);
            g5.push(ie);
            g5.push(is_dc);
            // Thermal node: Gth*(V_T - 0) - P_diss = 0  →  g[4] = gth*v_t - p_diss
            // But v_t isn't in our voltages slice here unless a 5th voltage is passed.
            // We stamp it as a Norton equivalent: current = -P_diss (source) + Gth*V_T (conductance).
            // The solver will pass V_T when voltages.len() >= 5; until then we approximate.
            let v_thermal = if voltages.len() >= 5 { voltages[4] } else { 0.0 };
            g5.push(gth * v_thermal - p_diss);

            let mut jac5: SmallVec<[(u8, u8, f64); 8]> = SmallVec::new();
            // Copy 4x4 core Jacobian.
            jac5.push((0, 0,  dic_dvc + gmin));
            jac5.push((0, 1,  dic_dvb - gmin));
            jac5.push((0, 2,  dic_dve));
            jac5.push((1, 0,  dib_dvc - gmin));
            jac5.push((1, 1,  dib_dvb + 3.0 * gmin));
            jac5.push((1, 2,  dib_dve - gmin));
            jac5.push((1, 3,  dib_dvs - gmin));
            jac5.push((2, 0,  die_dvc));
            jac5.push((2, 1,  die_dvb - gmin));
            jac5.push((2, 2,  die_dve + gmin));
            jac5.push((3, 1,  dis_dvb - gmin));
            jac5.push((3, 3,  dis_dvs + gmin));
            // Thermal row: d(g[4])/dV_j = -dP_diss/dV_j  +  Gth * delta(j==4)
            jac5.push((4, 0, -dp_dvc_exact));
            jac5.push((4, 1, -dp_dvb));
            jac5.push((4, 2, -dp_dve));
            jac5.push((4, 4,  gth));

            let mut cap5: SmallVec<[(u8, u8, f64); 8]> = SmallVec::new();
            if cth > 0.0 {
                cap5.push((4, 4, cth));
            }

            return DeviceEval {
                g: g5,
                q: smallvec![0.0, 0.0, 0.0, 0.0, 0.0],
                G: jac5,
                C: cap5,
                rhs: SmallVec::new(),
            };
        }

        // ── Assemble DeviceEval (4 terminals: C, B, E, S) ─────────────────────
        DeviceEval {
            g: smallvec![ic, ib, ie, is_dc],
            q: smallvec![0.0, 0.0, 0.0, 0.0],
            G: smallvec![
                // Collector row (pin 0)
                (0, 0,  dic_dvc + gmin),
                (0, 1,  dic_dvb - gmin),
                (0, 2,  dic_dve),
                // Base row (pin 1)
                (1, 0,  dib_dvc - gmin),
                (1, 1,  dib_dvb + 3.0 * gmin),
                (1, 2,  dib_dve - gmin),
                (1, 3,  dib_dvs - gmin),
                // Emitter row (pin 2)
                (2, 0,  die_dvc),
                (2, 1,  die_dvb - gmin),
                (2, 2,  die_dve + gmin),
                // Substrate row (pin 3)
                (3, 1,  dis_dvb - gmin),
                (3, 3,  dis_dvs + gmin),
            ],
            C: SmallVec::new(),
            rhs: SmallVec::new(),
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// BC547-like VBIC parameter set (DC-critical parameters only).
    /// Tuned to give Ic ≈ 1.9 mA at Vbe=0.7 V, Vce=3 V.
    fn bc547_params() -> ParamMap {
        let mut p = ParamMap::new();
        // Transport — is=3.5e-15 gives If ≈ 1.9 mA at Vbe=0.7 V (Vt=25.85 mV)
        p.set("is",   3.5e-15);
        p.set("nf",   1.0);
        p.set("nr",   1.0);
        p.set("vef",  100.0);
        p.set("ver",  10.0);
        p.set("ikf",  0.03);
        p.set("ikr",  1e30);
        // Base currents (ibei/bf_eff ≈ 200)
        p.set("ibei",  2.5e-18);
        p.set("nei",   1.0);
        p.set("iben",  0.0);
        p.set("nen",   2.0);
        p.set("ibci",  5.0e-16);
        p.set("nci",   1.0);
        p.set("ibcn",  0.0);
        p.set("ncn",   2.0);
        p.set("vt",    0.02585);
        p
    }

    // ── Finite difference helper ───────────────────────────────────────────
    fn jacobian_max_rel_err(vbic: &Vbic, v: &[f64; 4], params: &ParamMap) -> f64 {
        let h = 1e-5_f64;
        let e0 = vbic.eval(v, params);
        let mut max_err = 0.0_f64;
        // Only check the 3 active pins (C, B, E); pin 3 = substrate = 0
        for col in 0u8..3 {
            let mut vp = *v;
            let mut vm = *v;
            vp[col as usize] += h;
            vm[col as usize] -= h;
            let ep = vbic.eval(&vp, params);
            let em = vbic.eval(&vm, params);
            for row in 0u8..3 {
                let fd = (ep.g[row as usize] - em.g[row as usize]) / (2.0 * h);
                let analytic = e0.G.iter()
                    .find(|(r, c, _)| *r == row && *c == col)
                    .map(|(_, _, val)| *val)
                    .unwrap_or(0.0);
                let scale = analytic.abs().max(fd.abs()).max(1e-20);
                let rel = (fd - analytic).abs() / scale;
                if rel > max_err { max_err = rel; }
            }
        }
        max_err
    }

    #[test]
    fn vbic_npn_forward_active_ic_positive() {
        // NPN at Vbe=0.7 V, Vce=3 V — Ic must be > 0 and in mA range.
        let q = Vbic::npn();
        let p = bc547_params();
        let eval = q.eval(&[3.0, 0.7, 0.0, 0.0], &p);

        let ic = eval.g[0];
        let ib = eval.g[1];
        let ie = eval.g[2];

        assert!(ic > 0.0, "Ic should be > 0, got {ic}");
        assert!(ib > 0.0, "Ib should be > 0, got {ib}");
        assert!(ie < 0.0, "Ie should be < 0, got {ie}");

        // KCL on active terminals
        let kcl = ic + ib + ie;
        assert!(kcl.abs() < 1e-6, "KCL violated: {kcl}");

        // Ic should be in ballpark of 1-10 mA (roughly ngspice BC547 range at Vbe=0.7)
        assert!(ic > 1e-4 && ic < 1e-1, "Ic={ic} out of BC547 range");
    }

    #[test]
    fn vbic_npn_forward_active_vs_ngspice_5pct() {
        // BC547-like DC operating point: Vbe=0.7, Vce=3 → Ic ≈ 1.9 mA (ngspice reference).
        // We verify Ic matches within 5%.
        let q = Vbic::npn();
        let p = bc547_params();
        let eval = q.eval(&[3.0, 0.7, 0.0, 0.0], &p);
        let ic = eval.g[0];

        // ngspice reference: Ic ≈ 1.9 mA for these params
        let ic_ref = 1.9e-3_f64;
        let rel_err = (ic - ic_ref).abs() / ic_ref;
        assert!(
            rel_err < 0.05,
            "Ic={ic:.4e} vs reference {ic_ref:.4e}: rel_err={rel_err:.4} > 5%"
        );
    }

    #[test]
    fn vbic_npn_cutoff() {
        let q = Vbic::npn();
        let p = bc547_params();
        let eval = q.eval(&[0.0, 0.0, 0.0, 0.0], &p);
        assert!(eval.g[0].abs() < 1e-10, "cutoff Ic: {}", eval.g[0]);
        assert!(eval.g[1].abs() < 1e-10, "cutoff Ib: {}", eval.g[1]);
        assert!(eval.g[2].abs() < 1e-10, "cutoff Ie: {}", eval.g[2]);
    }

    #[test]
    fn vbic_pnp_forward_active() {
        // PNP forward active: Ve=5, Vb=4.3, Vc=0, Vs=0
        let q = Vbic::pnp();
        let p = bc547_params();
        let eval = q.eval(&[0.0, 4.3, 5.0, 0.0], &p);

        assert!(eval.g[0] < 0.0, "PNP Ic should be < 0, got {}", eval.g[0]);
        assert!(eval.g[1] < 0.0, "PNP Ib should be < 0, got {}", eval.g[1]);
        assert!(eval.g[2] > 0.0, "PNP Ie should be > 0, got {}", eval.g[2]);

        let kcl = eval.g[0] + eval.g[1] + eval.g[2];
        assert!(kcl.abs() < 1e-6, "PNP KCL: {kcl}");
    }

    #[test]
    fn vbic_npn_kind() {
        assert_eq!(Vbic::npn().kind(), DeviceKind::VbicNpn);
        assert_eq!(Vbic::pnp().kind(), DeviceKind::VbicPnp);
    }

    #[test]
    fn vbic_npn_4_terminals() {
        assert_eq!(Vbic::npn().num_terminals(), 4);
    }

    #[test]
    fn vbic_npn_jacobian_fd() {
        let q = Vbic::npn();
        let p = bc547_params();
        let max_err = jacobian_max_rel_err(&q, &[3.0, 0.7, 0.0, 0.0], &p);
        assert!(max_err < 5e-2, "VBIC Jacobian FD error: {max_err}");
    }

    #[test]
    fn vbic_npn_overflow_protection() {
        let q = Vbic::npn();
        let p = bc547_params();
        // Insanely large Vbe — must produce finite currents.
        let eval = q.eval(&[5.0, 5.0, 0.0, 0.0], &p);
        assert!(eval.g[0].is_finite(), "Ic not finite");
        assert!(eval.g[1].is_finite(), "Ib not finite");
        assert!(eval.g[2].is_finite(), "Ie not finite");
    }

    #[test]
    fn vbic_npn_kcl_all_regions() {
        let q = Vbic::npn();
        let p = bc547_params();
        let test_points: &[[f64; 4]] = &[
            [3.0, 0.7, 0.0, 0.0],   // forward active
            [0.2, 0.7, 0.0, 0.0],   // saturation
            [0.0, 0.0, 0.0, 0.0],   // cutoff
            [5.0, 0.85, 0.0, 0.0],  // high injection
        ];
        for v in test_points {
            let eval = q.eval(v, &p);
            let kcl = eval.g[0] + eval.g[1] + eval.g[2] + eval.g[3];
            assert!(kcl.abs() < 1e-6, "KCL failed at {:?}: {kcl}", v);
        }
    }

    #[test]
    fn vbic_early_effect() {
        // With vef=50, Ic should increase with Vce.
        let q = Vbic::npn();
        let mut p = bc547_params();
        p.set("vef", 50.0);

        let ic_lo = q.eval(&[1.0, 0.7, 0.0, 0.0], &p).g[0];
        let ic_hi = q.eval(&[5.0, 0.7, 0.0, 0.0], &p).g[0];
        assert!(ic_hi > ic_lo, "Early effect: Ic should increase with Vce");
    }

    // ── Avalanche / weak-avalanche tests ──────────────────────────────────────

    /// With avc1=0 (default), avalanche must be exactly zero — bit-identical
    /// to the pre-avalanche behavior.
    #[test]
    fn vbic_avalanche_off_by_default() {
        let q = Vbic::npn();
        let p = bc547_params();
        // Default param set has no avc1 → avalanche disabled.
        let e = q.eval(&[3.0, 0.7, 0.0, 0.0], &p);
        let ic_no_av = e.g[0];

        let mut p2 = bc547_params();
        p2.set("avc1", 0.0);
        p2.set("avc2", 0.0);
        let e2 = q.eval(&[3.0, 0.7, 0.0, 0.0], &p2);
        assert!((ic_no_av - e2.g[0]).abs() < 1e-15);
    }

    /// With avalanche enabled and a high reverse Vbc bias, Ic must increase
    /// (multiplication injects extra collector current) and Ib must decrease
    /// (or even reverse) by the same amount.
    #[test]
    fn vbic_avalanche_increases_ic_at_high_vce() {
        let q = Vbic::npn();
        let mut p = bc547_params();
        // Enable mild avalanche.
        p.set("avc1", 5.0);
        p.set("avc2", 2.0);
        p.set("pc",   0.75);
        p.set("mc",   0.33);

        // Baseline (Vce = 3 V, no avalanche)
        let mut p_base = p.clone();
        p_base.set("avc1", 0.0);
        let e_base = q.eval(&[3.0, 0.7, 0.0, 0.0], &p_base);
        let ic_base = e_base.g[0];
        let ib_base = e_base.g[1];

        // Avalanche on
        let e_av = q.eval(&[3.0, 0.7, 0.0, 0.0], &p);
        let ic_av = e_av.g[0];
        let ib_av = e_av.g[1];

        // Ic must rise, Ib must fall by ~the same amount (charge conservation
        // — Iavl just routes some collector current through the base path).
        assert!(ic_av >= ic_base, "avalanche Ic={ic_av} should be >= baseline {ic_base}");
        assert!(ib_av <= ib_base, "avalanche Ib={ib_av} should be <= baseline {ib_base}");

        let dic = ic_av - ic_base;
        let dib = ib_base - ib_av;
        // dic ≈ dib (Iavl is internal: +collector, −base)
        assert!((dic - dib).abs() < 1e-9 + 0.01 * dic.abs(),
            "Iavl charge mismatch: dIc={dic:.4e}, dIb={dib:.4e}");
    }

    /// KCL must still hold across all 4 terminals when avalanche + substrate
    /// are active.
    #[test]
    fn vbic_avalanche_substrate_kcl() {
        let q = Vbic::npn();
        let mut p = bc547_params();
        p.set("avc1", 5.0);
        p.set("avc2", 2.0);
        p.set("isp",   1e-16);
        p.set("nfp",   1.0);
        p.set("ibcip", 1e-17);
        p.set("ncip",  1.0);

        // Forward active with substrate slightly forward biased
        let v = [3.0_f64, 0.7, 0.0, -0.1];
        let e = q.eval(&v, &p);
        let kcl = e.g[0] + e.g[1] + e.g[2] + e.g[3];
        assert!(kcl.abs() < 1e-6, "KCL with av+subs: {kcl:.4e}, g={:?}", &e.g[..]);
    }

    /// Parasitic substrate junction must produce a non-zero substrate
    /// current when forward biased — and zero when isp=ibcip=ibcnp=0.
    #[test]
    fn vbic_substrate_current_active_when_isp_set() {
        let q = Vbic::npn();
        let mut p = bc547_params();
        // Strongly forward bias the parasitic Vbcp junction (Vb=0.7, Vs=0)
        p.set("isp",   1e-15);
        p.set("ibcip", 1e-16);
        p.set("nfp",   1.0);
        p.set("ncip",  1.0);

        let e = q.eval(&[3.0, 0.7, 0.0, 0.0], &p);
        // Substrate sinks current — i.e. g[3] ≠ 0
        assert!(e.g[3].abs() > 1e-12,
            "expected non-zero substrate current, got Is={}", e.g[3]);
        // KCL holds
        let kcl = e.g[0] + e.g[1] + e.g[2] + e.g[3];
        assert!(kcl.abs() < 1e-6, "KCL: {kcl}");
    }

    // ── Thermal node tests ────────────────────────────────────────────────────

    /// With rth > 0, eval must return 5 currents (pins C, B, E, S, T).
    #[test]
    fn vbic_thermal_returns_5_currents() {
        let q = Vbic::npn_thermal();
        let mut p = bc547_params();
        p.set("rth", 100.0); // 100 K/W
        p.set("cth", 1e-9);  // 1 nJ/K

        // voltages: Vc=3, Vb=0.7, Ve=0, Vs=0, V_thermal=0
        let eval = q.eval(&[3.0, 0.7, 0.0, 0.0, 0.0], &p);
        assert_eq!(eval.g.len(), 5, "thermal eval must produce 5 currents");
        assert_eq!(eval.q.len(), 5, "thermal eval must produce 5 charges");
    }

    /// Thermal conductance Gth = 1/rth must appear as (4,4) in the G Jacobian.
    #[test]
    fn vbic_thermal_gth_stamp() {
        let q = Vbic::npn_thermal();
        let mut p = bc547_params();
        let rth = 200.0_f64;
        p.set("rth", rth);

        let eval = q.eval(&[3.0, 0.7, 0.0, 0.0, 0.0], &p);

        let gth_stamp = eval.G.iter()
            .find(|&&(r, c, _)| r == 4 && c == 4)
            .map(|&(_, _, v)| v);

        assert!(
            gth_stamp.is_some(),
            "G[4,4] (Gth) must be present in the Jacobian"
        );
        let gth = gth_stamp.unwrap();
        let expected = 1.0 / rth;
        assert!(
            (gth - expected).abs() < 1e-15,
            "G[4,4] = {gth} but expected 1/rth = {expected}"
        );
    }

    /// Thermal capacitance Cth must appear as (4,4) in the C Jacobian.
    #[test]
    fn vbic_thermal_cth_stamp() {
        let q = Vbic::npn_thermal();
        let mut p = bc547_params();
        p.set("rth", 100.0);
        let cth = 5e-9_f64;
        p.set("cth", cth);

        let eval = q.eval(&[3.0, 0.7, 0.0, 0.0, 0.0], &p);

        let cth_stamp = eval.C.iter()
            .find(|&&(r, c, _)| r == 4 && c == 4)
            .map(|&(_, _, v)| v);

        assert!(
            cth_stamp.is_some(),
            "C[4,4] (Cth) must be present in the C Jacobian"
        );
        assert!(
            (cth_stamp.unwrap() - cth).abs() < 1e-30,
            "C[4,4] = {} but expected cth = {cth}",
            cth_stamp.unwrap()
        );
    }

    /// Power dissipation current into pin 4 must be positive in forward active.
    /// At Vce=3 V, Ic ≈ 1.9 mA, Vbe=0.7 V, Ib ≈ Ic/beta:
    ///   P_diss = Vce*Ic + Vbe*Ib > 0
    /// The thermal KCL residual at pin 4 = Gth*V_T - P_diss; at V_T=0 it equals -P_diss.
    #[test]
    fn vbic_thermal_power_dissipation_positive() {
        let q = Vbic::npn_thermal();
        let mut p = bc547_params();
        p.set("rth", 100.0);

        // V_thermal = 0 → g[4] = Gth*0 - P_diss = -P_diss (negative = current into node)
        let eval = q.eval(&[3.0, 0.7, 0.0, 0.0, 0.0], &p);
        let g4 = eval.g[4];
        // g[4] = Gth*V_T - P_diss; with V_T=0: g[4] = -P_diss
        // Since P_diss > 0 (forward active), g[4] < 0 meaning net current flows in.
        assert!(
            g4 < 0.0,
            "g[4] = {g4}; expected < 0 (= -P_diss) in forward active at V_T=0"
        );
    }

    /// KCL on the 4 electrical terminals must still hold when thermal is active.
    #[test]
    fn vbic_thermal_electrical_kcl() {
        let q = Vbic::npn_thermal();
        let mut p = bc547_params();
        p.set("rth", 100.0);
        p.set("cth", 1e-9);

        let eval = q.eval(&[3.0, 0.7, 0.0, 0.0, 0.1], &p);
        // KCL on electrical pins: Ic + Ib + Ie + Is = 0
        let kcl = eval.g[0] + eval.g[1] + eval.g[2] + eval.g[3];
        assert!(kcl.abs() < 1e-6, "KCL with thermal: {kcl}");
    }

    /// With rth=0 (default), eval must NOT return the thermal path (4 currents).
    #[test]
    fn vbic_no_rth_gives_4_currents() {
        let q = Vbic::npn();
        let p = bc547_params(); // no rth set → defaults to 0
        let eval = q.eval(&[3.0, 0.7, 0.0, 0.0], &p);
        assert_eq!(eval.g.len(), 4, "non-thermal eval must produce 4 currents");
    }

    /// Jacobian FD check with avalanche + substrate active.
    #[test]
    fn vbic_jacobian_fd_with_avalanche_and_substrate() {
        let q = Vbic::npn();
        let mut p = bc547_params();
        p.set("avc1",  5.0);
        p.set("avc2",  2.0);
        p.set("isp",   1e-16);
        p.set("ibcip", 1e-17);
        // Use a fully 4-pin FD (we extend the helper inline).
        let v = [3.0_f64, 0.7, 0.0, 0.0];
        let h = 1e-5_f64;
        let e0 = q.eval(&v, &p);
        let mut max_err = 0.0_f64;
        for col in 0u8..4 {
            let mut vp = v;
            let mut vm = v;
            vp[col as usize] += h;
            vm[col as usize] -= h;
            let ep = q.eval(&vp, &p);
            let em = q.eval(&vm, &p);
            for row in 0u8..4 {
                let fd = (ep.g[row as usize] - em.g[row as usize]) / (2.0 * h);
                let analytic = e0.G.iter()
                    .find(|(r, c, _)| *r == row && *c == col)
                    .map(|(_, _, val)| *val)
                    .unwrap_or(0.0);
                let scale = analytic.abs().max(fd.abs()).max(1e-15);
                let rel = (fd - analytic).abs() / scale;
                if rel > max_err { max_err = rel; }
            }
        }
        assert!(max_err < 1e-1, "VBIC FD with av/subs: max rel err = {max_err}");
    }
}
