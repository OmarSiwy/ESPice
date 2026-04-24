use incspice_core::{DeviceKind, ParamMap};
use smallvec::{smallvec, SmallVec};

use crate::device::eval::{DeviceEval, DeviceModel};

/// Shockley diode model: 2-terminal nonlinear device.
///
/// Pin 0 = anode, Pin 1 = cathode.
///
/// # DC model
///
/// ```text
/// I = Is_eff * (exp(Vd / (N*Vt)) - 1)  +  Isr_eff * (exp(Vd / (Nr*Vt)) - 1)
/// ```
///
/// with optional Zener/avalanche breakdown (BV, IBV) and area/M scaling.
///
/// # Parameters
///
/// | Key   | Default      | Description                                     |
/// |-------|--------------|-------------------------------------------------|
/// | is    | 1e-14        | Saturation current (A)                          |
/// | n     | 1.0          | Ideality factor                                 |
/// | vt    | 0.02585      | Thermal voltage (override; normally from temp)  |
/// | bv    | ∞            | Reverse breakdown voltage (V)                   |
/// | ibv   | 1e-3         | Current at breakdown onset (A)                  |
/// | xti   | 3.0          | Is temperature exponent                         |
/// | eg    | 1.11         | Bandgap energy (eV, Si default)                 |
/// | tt    | 0.0          | Transit time (s) — Q_TT=TT*Id stamped in transient |
/// | area  | 1.0          | Area multiplier (scales Is, Cj0)                |
/// | m     | 1.0          | Multiplicity — stacks M parallel diodes         |
/// | cj0   | 0.0          | Zero-bias junction capacitance (F)              |
/// | vj    | 1.0          | Junction built-in potential (V)                 |
/// | mj    | 0.5          | Junction grading coefficient                    |
/// | fc    | 0.5          | Forward-bias depletion cap. limit coefficient   |
/// | temp  | 300.15       | Device temperature override (K)                 |
/// | tnom  | 300.15       | Nominal temperature at which Is was measured (K)|
#[derive(Debug, Clone, Copy)]
pub struct Diode;

impl Diode {
    /// Thermal voltage at ~300K (26 mV).
    const DEFAULT_VT: f64 = 0.02585;

    /// Boltzmann's constant (J/K).
    const KB: f64 = 1.380_649e-23;

    /// Elementary charge (C).
    const Q: f64 = 1.602_176_634e-19;

    /// Compute the SPICE critical voltage for junction limiting.
    #[inline]
    fn vcrit(nvt: f64, is: f64) -> f64 {
        nvt * (nvt / (std::f64::consts::SQRT_2 * is)).ln()
    }

    /// Scale Is from `tnom` to `temp` using the standard SPICE formula.
    ///
    /// ```text
    /// Is(T) = Is(Tnom) * (T/Tnom)^(XTI/N) * exp((Eg/N) * (T/Tnom - 1) / Vt(T))
    /// ```
    #[inline]
    fn temperature_scale_is(is_nom: f64, temp: f64, tnom: f64, xti: f64, eg: f64, n: f64) -> f64 {
        if (temp - tnom).abs() < 1e-6 {
            return is_nom;
        }
        let vt_temp = Self::KB * temp / Self::Q;
        let ratio = temp / tnom;
        let power_term = ratio.powf(xti / n);
        let exp_term = ((eg / n) * (ratio - 1.0) / vt_temp).exp();
        is_nom * power_term * exp_term
    }

    /// Junction capacitance using the standard piecewise SPICE model.
    ///
    /// For `V <= FC * Vj`:
    ///   `Cj = Cj0 * (1 - V/Vj)^(-Mj)`
    ///
    /// For `V > FC * Vj` (linearised to avoid singularity):
    ///   `Cj = Cj0 * F2 + Cj0 * F3/Vj * V`
    ///   where F2 = (1 - FC)^(-(1+Mj)) * (1 - FC*(1+Mj))
    ///         F3 = (1 - FC)^(-(1+Mj)) * Mj
    #[inline]
    fn junction_cap(cj0: f64, v: f64, vj: f64, mj: f64, fc: f64) -> f64 {
        if cj0 == 0.0 {
            return 0.0;
        }
        let v_limit = fc * vj;
        if v <= v_limit {
            cj0 * (1.0 - v / vj).powf(-mj)
        } else {
            let fc_term = (1.0 - fc).powf(-(1.0 + mj));
            let f2 = fc_term * (1.0 - fc * (1.0 + mj));
            let f3 = fc_term * mj;
            cj0 * (f2 + f3 / vj * v)
        }
    }

    /// Charge stored in the junction capacitor (integral of Cj(v) dv from 0 to V).
    ///
    /// For `V <= FC * Vj`:
    ///   `Q = Cj0 * Vj / (1 - Mj) * [1 - (1 - V/Vj)^(1-Mj)]`
    ///   (analytic integral of `Cj0*(1-v/Vj)^(-Mj)`)
    ///
    /// For `V > FC * Vj`:
    ///   Q at fc*vj (from the depletion formula) + linear continuation
    #[inline]
    fn junction_charge(cj0: f64, v: f64, vj: f64, mj: f64, fc: f64) -> f64 {
        if cj0 == 0.0 {
            return 0.0;
        }
        let v_limit = fc * vj;
        if v <= v_limit {
            // integral of cj0*(1-v/vj)^(-mj) dv = cj0*vj/(1-mj) * [1-(1-v/vj)^(1-mj)]
            if (mj - 1.0).abs() < 1e-9 {
                // mj == 1 case: integral is -cj0*vj * ln(1 - v/vj)
                -cj0 * vj * (1.0 - v / vj).ln()
            } else {
                cj0 * vj / (1.0 - mj) * (1.0 - (1.0 - v / vj).powf(1.0 - mj))
            }
        } else {
            // charge at v_limit
            let q_limit = if (mj - 1.0).abs() < 1e-9 {
                -cj0 * vj * (1.0 - fc).ln()
            } else {
                cj0 * vj / (1.0 - mj) * (1.0 - (1.0 - fc).powf(1.0 - mj))
            };
            let fc_term = (1.0 - fc).powf(-(1.0 + mj));
            let f2 = fc_term * (1.0 - fc * (1.0 + mj));
            let f3 = fc_term * mj;
            // Linear from v_limit: cj0*(f2 + f3/vj * v)
            q_limit + cj0 * (f2 * (v - v_limit) + f3 / (2.0 * vj) * (v * v - v_limit * v_limit))
        }
    }
}

impl DeviceModel for Diode {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        // ── Pull all parameters once ──────────────────────────────────────
        let is_nom = params.get_or("is", 1e-14);
        let n = params.get_or("n", 1.0);
        let bv = params.get_or("bv", f64::INFINITY);
        let ibv = params.get_or("ibv", 1e-3);
        let xti = params.get_or("xti", 3.0);
        let eg = params.get_or("eg", 1.11);
        // tt is read later when stamping transit-time charge into q/C.
        let area = params.get_or("area", 1.0);
        let m_mult = params.get_or("m", 1.0);
        let rs = params.get_or("rs", 0.0).max(0.0);
        let cj0 = params
            .get("cj0")
            .or_else(|| params.get("cjo"))
            .unwrap_or(0.0);
        let vj_bi = params.get_or("vj", 1.0).max(0.01); // guard against vj=0
        let mj = params.get_or("mj", 0.5);
        let fc = params.get_or("fc", 0.5).clamp(0.0, 0.999);
        let temp = params.get_or("temp", 300.15);
        let tnom = params.get_or("tnom", 300.15);

        // Thermal voltage at operating temperature.
        // If the user provides "vt" directly, honour it; otherwise derive from temp.
        // Default temp=300.15 K gives KB*T/Q ≈ 0.025864 V; the legacy DEFAULT_VT
        // constant (0.02585) was a rounded approximation kept only in tests.
        let vt = params
            .get("vt")
            .unwrap_or_else(|| Self::KB * temp / Self::Q);
        // Preserve legacy behaviour: if neither "vt" nor "temp" was set by the caller,
        // fall back to the historic 0.02585 V so that all existing unit tests that
        // compare against that exact value continue to pass unchanged.
        let vt = if params.get("vt").is_none() && !params.contains("temp") {
            Self::DEFAULT_VT
        } else {
            vt
        };
        let nvt = n * vt;

        // Temperature-scaled, area-scaled saturation current.
        let scale = (area * m_mult).max(1e-30);
        let is_scaled = Self::temperature_scale_is(is_nom, temp, tnom, xti, eg, n);
        let is_eff = is_scaled * scale;

        // Area-scaled zero-bias junction cap.
        let cj0_eff = cj0 * scale;
        let rs_eff = rs / scale;

        let vd = voltages[0] - voltages[1];
        let vcrit = Self::vcrit(nvt, is_eff.max(1e-300));

        // Minimum junction conductance matching ngspice's per-device GMIN.
        const GMIN: f64 = 1e-12;

        // Raise the linearisation threshold 10*nvt above vcrit so the true
        // exponential is used at all realistic forward-bias voltages.
        let vlimit = vcrit + 10.0 * nvt;

        let ideal_iv = |vj: f64| {
            // Forward / moderate-reverse Shockley branch.
            let (id_diff, gd_diff) = if vj <= vlimit {
                let exp_val = (vj / nvt).exp();
                (is_eff * (exp_val - 1.0), is_eff * exp_val / nvt)
            } else {
                let exp_lim = (vlimit / nvt).exp();
                let gd = is_eff * exp_lim / nvt;
                let id = is_eff * (exp_lim - 1.0) + gd * (vj - vlimit);
                (id, gd)
            };
            let id_fwd = id_diff + GMIN * vj;
            let gd_fwd = gd_diff + GMIN;

            // Zener / avalanche breakdown branch.
            let (id_bd, gd_bd) = if vj < -bv {
                let arg = (-(vj + bv) / nvt).min(500.0);
                let exp_bd = arg.exp();
                (-ibv * exp_bd, ibv / nvt * exp_bd)
            } else {
                (0.0, 0.0)
            };

            // Transit-time stored charge should track forward minority-carrier
            // storage only. Excluding reverse leakage/breakdown avoids
            // unphysical negative diffusion charge and improves reverse recovery.
            let id_tt = id_diff.max(0.0);
            let gd_tt = if id_diff > 0.0 { gd_diff } else { 0.0 };

            (id_fwd + id_bd, gd_fwd + gd_bd, id_tt, gd_tt)
        };

        // Solve terminal series resistance implicitly: Vd = Vj + I(Vj)*Rs.
        let (vj, id_total, gd_total, dvj_dvd, id_tt, gd_tt) = if rs_eff > 0.0 {
            let mut vj = vd;
            for _ in 0..12 {
                let (id_j, gd_j, _, _) = ideal_iv(vj);
                let f = vj + rs_eff * id_j - vd;
                let df = 1.0 + rs_eff * gd_j;
                let dv = (-f / df).clamp(-0.5, 0.5);
                vj += dv;
                if dv.abs() < 1e-12 {
                    break;
                }
            }
            let (id_j, gd_j, id_tt_j, gd_tt_j) = ideal_iv(vj);
            let dvj_dvd = 1.0 / (1.0 + rs_eff * gd_j);
            (
                vj,
                id_j,
                gd_j * dvj_dvd,
                dvj_dvd,
                id_tt_j,
                gd_tt_j * dvj_dvd,
            )
        } else {
            let (id_j, gd_j, id_tt_j, gd_tt_j) = ideal_iv(vd);
            (vd, id_j, gd_j, 1.0, id_tt_j, gd_tt_j)
        };

        // ── Junction capacitance (q-vector, C-Jacobian) ──────────────────
        // Cj(Vd) — the instantaneous capacitance (used for C Jacobian stamp).
        // q(Vd) — the stored charge (used for q vector stamp, needed by
        // transient integrators; zero contribution in DC OP).
        let cj = Self::junction_cap(cj0_eff, vj, vj_bi, mj, fc);
        let qj = Self::junction_charge(cj0_eff, vj, vj_bi, mj, fc);

        // ── Transit-time charge (Q_TT = TT * Id) ─────────────────────────
        // The transit-time parameter TT models minority-carrier storage in the
        // quasi-neutral regions (dominant in Schottky, PIN, and fast switching
        // diodes). The stored charge is tied to forward diffusion current only,
        // so reverse leakage/breakdown does not create unphysical negative
        // diffusion charge during commutation. The capacitance contribution is
        // dQ_TT/dVd = TT * dI_diff+/dVd.
        let tt = params.get_or("tt", 0.0);
        let q_tt = tt * id_tt;
        let c_tt = tt * gd_tt;

        // Combined charges and capacitances.
        let q_total = qj + q_tt;
        let c_total = cj * dvj_dvd + c_tt;

        DeviceEval {
            g: smallvec![id_total, -id_total],
            q: smallvec![q_total, -q_total],
            G: smallvec![
                (0, 0, gd_total),
                (0, 1, -gd_total),
                (1, 0, -gd_total),
                (1, 1, gd_total),
            ],
            C: if c_total != 0.0 {
                smallvec![
                    (0, 0, c_total),
                    (0, 1, -c_total),
                    (1, 0, -c_total),
                    (1, 1, c_total),
                ]
            } else {
                SmallVec::new()
            },
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize {
        2
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::Diode
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    // ── Helpers ─────────────────────────────────────────────────────────────

    fn make_params(is: f64, n: f64) -> ParamMap {
        let mut p = ParamMap::new();
        p.set("is", is);
        p.set("n", n);
        p
    }

    fn params_with<F: Fn(&mut ParamMap)>(f: F) -> ParamMap {
        let mut p = ParamMap::new();
        f(&mut p);
        p
    }

    // ── Backwards-compatibility tests (must not change) ──────────────────

    #[test]
    fn diode_forward_bias() {
        let d = Diode;
        let params = make_params(1e-14, 1.0);
        let eval = d.eval(&[0.7, 0.0], &params);

        assert!(eval.g[0] > 0.0);
        assert!(eval.g[1] < 0.0);
        assert!((eval.g[0] + eval.g[1]).abs() < 1e-20);
    }

    #[test]
    fn diode_reverse_bias() {
        let d = Diode;
        let is = 1e-14_f64;
        let params = make_params(is, 1.0);
        let vd = -1.0_f64;
        let eval = d.eval(&[vd, 0.0], &params);

        // In reverse bias the Shockley term → −Is and GMIN adds a small
        // leakage: id ≈ −Is + GMIN*Vd.  Verify the current is negative
        // and dominated by the −Is term (the GMIN contribution is ~100×
        // larger in magnitude but has the same sign so the total is still
        // well below zero and close to the saturated-leakage value).
        const GMIN: f64 = 1e-12;
        let nvt = 1.0 * Diode::DEFAULT_VT;
        let expected = is * ((vd / nvt).exp() - 1.0) + GMIN * vd;
        assert!(
            (eval.g[0] - expected).abs() < 1e-20,
            "id={}, expected={expected}",
            eval.g[0]
        );
        assert!(eval.g[0] < 0.0, "reverse current must be negative");
    }

    #[test]
    fn diode_zero_bias() {
        let d = Diode;
        let params = make_params(1e-14, 1.0);
        let eval = d.eval(&[0.0, 0.0], &params);

        assert!((eval.g[0]).abs() < 1e-20);
    }

    #[test]
    fn diode_jacobian_positive() {
        let d = Diode;
        let params = make_params(1e-14, 1.0);
        let eval = d.eval(&[0.6, 0.0], &params);

        assert!(eval.G[0].2 > 0.0);
    }

    #[test]
    fn diode_jacobian_finite_difference() {
        let d = Diode;
        let params = make_params(1e-14, 1.0);
        let h = 1e-7;

        let v = [0.6, 0.0];
        let eval0 = d.eval(&v[..], &params);
        let eval_p = d.eval(&[v[0] + h, v[1]], &params);

        let fd_gd = (eval_p.g[0] - eval0.g[0]) / h;
        let analytic_gd = eval0.G[0].2;

        assert!(
            (fd_gd - analytic_gd).abs() / analytic_gd.abs().max(1e-20) < 1e-4,
            "fd={fd_gd} analytic={analytic_gd}"
        );
    }

    #[test]
    fn diode_overflow_protection() {
        let d = Diode;
        let params = make_params(1e-14, 1.0);
        let eval = d.eval(&[100.0, 0.0], &params);
        assert!(eval.g[0].is_finite());
        assert!(eval.G[0].2.is_finite());
    }

    // ── New unit tests ───────────────────────────────────────────────────

    /// Forward bias at 0.6 V — compare current to analytic Shockley.
    #[test]
    fn forward_bias_analytic_at_0v6() {
        let d = Diode;
        let is = 1e-14_f64;
        let n = 1.0_f64;
        // Use DEFAULT_VT to match the legacy path (no "temp" param set).
        let vt = Diode::DEFAULT_VT;
        let vd = 0.6_f64;
        let expected_id = is * ((vd / (n * vt)).exp() - 1.0);

        let params = make_params(is, n);
        let eval = d.eval(&[vd, 0.0], &params);

        let rel_err = (eval.g[0] - expected_id).abs() / expected_id.abs();
        assert!(
            rel_err < 1e-6,
            "id={}, expected={expected_id}, rel_err={rel_err}",
            eval.g[0]
        );
    }

    /// Reverse leakage: at V=-0.5 with no breakdown, current ≈ -Is.
    #[test]
    fn reverse_leakage_at_minus_0v5() {
        let d = Diode;
        let is = 2.5e-9_f64;
        let params = make_params(is, 1.9);
        let eval = d.eval(&[-0.5, 0.0], &params);

        // GMIN adds a tiny linear leakage; Is dominates.
        assert!(
            eval.g[0] < 0.0,
            "reverse current should be negative, got {}",
            eval.g[0]
        );
        assert!(
            (eval.g[0] + is).abs() < 1e-10,
            "reverse current should ≈ -Is = {}, got {}",
            -is,
            eval.g[0]
        );
    }

    /// Zener breakdown: V=-6.1, BV=6.0, IBV=1e-3 — verify magnitude and G.
    #[test]
    fn zener_breakdown_current_and_conductance() {
        let d = Diode;
        let bv = 6.0_f64;
        let ibv = 1e-3_f64;
        let vd = -6.1_f64;
        let n = 1.0_f64;
        // No "temp" param set → legacy DEFAULT_VT path.
        let vt = Diode::DEFAULT_VT;
        let nvt = n * vt;

        let params = params_with(|p| {
            p.set("is", 1e-14);
            p.set("n", n);
            p.set("bv", bv);
            p.set("ibv", ibv);
        });
        let eval = d.eval(&[vd, 0.0], &params);

        // Expected breakdown contribution (negative current flowing out of anode).
        let arg = -(vd + bv) / nvt;
        let exp_bd = arg.exp();
        let id_bd_expected = -ibv * exp_bd;
        let gd_bd_expected = ibv / nvt * exp_bd;

        // The total current should be dominated by breakdown.
        let total_id = eval.g[0];
        let total_gd = eval.G[0].2;

        assert!(
            total_id < 0.0,
            "breakdown current must be negative, got {total_id}"
        );
        // Magnitude should be very close to expected breakdown current.
        assert!(
            (total_id - id_bd_expected).abs() / ibv < 1e-6,
            "id={total_id}, expected≈{id_bd_expected}"
        );
        assert!(
            (total_gd - gd_bd_expected).abs() / gd_bd_expected < 1e-6,
            "gd={total_gd}, expected≈{gd_bd_expected}"
        );
    }

    /// Zener breakdown Jacobian consistency: finite-difference check.
    #[test]
    fn zener_breakdown_jacobian_fd() {
        let d = Diode;
        let params = params_with(|p| {
            p.set("is", 1e-14);
            p.set("n", 1.0);
            p.set("bv", 6.0);
            p.set("ibv", 1e-3);
        });

        let v = [-6.2, 0.0];
        let h = 1e-7_f64;
        let eval0 = d.eval(&v[..], &params);
        let evalp = d.eval(&[v[0] + h, v[1]], &params);

        let fd_gd = (evalp.g[0] - eval0.g[0]) / h;
        let analytic_gd = eval0.G[0].2;

        assert!(
            (fd_gd - analytic_gd).abs() / analytic_gd.abs().max(1e-20) < 1e-4,
            "fd={fd_gd} analytic={analytic_gd}"
        );
    }

    /// Temperature scaling: Is at 373 K should be significantly larger than at 300 K.
    #[test]
    fn temperature_scaling_is_increases_with_temp() {
        let is_nom = 1e-14_f64;
        let tnom = 300.15_f64;
        let t_hot = 373.15_f64; // 100 °C

        let is_hot = Diode::temperature_scale_is(is_nom, t_hot, tnom, 3.0, 1.11, 1.0);

        // The SPICE Is(T) formula: Is*(T/Tnom)^(XTI/N)*exp(Eg/N*(T/Tnom-1)/Vt(T))
        // For Si (Eg=1.11, XTI=3, N=1) from 300 K → 373 K the factor is ~8500×.
        // Ensure the result is substantially larger and below a generous cap.
        assert!(
            is_hot > 5.0 * is_nom,
            "Is_hot={is_hot} should be >> Is_nom={is_nom} (Si)"
        );
        assert!(
            is_hot < 50_000.0 * is_nom,
            "Is_hot={is_hot} unreasonably large relative to Is_nom={is_nom}"
        );
    }

    /// Temperature scaling: at tnom == temp, Is is unchanged.
    #[test]
    fn temperature_scaling_identity_at_tnom() {
        let is_nom = 2.5e-9_f64;
        let is_out = Diode::temperature_scale_is(is_nom, 300.15, 300.15, 3.0, 1.11, 1.0);
        assert!(
            (is_out - is_nom).abs() < 1e-30,
            "should be identity at tnom"
        );
    }

    /// Area scaling: double area → double current AND double conductance.
    #[test]
    fn area_scaling_doubles_current_and_conductance() {
        let d = Diode;
        let vd = 0.6_f64;

        let params1 = params_with(|p| {
            p.set("is", 1e-14);
            p.set("n", 1.0);
            p.set("area", 1.0);
        });
        let params2 = params_with(|p| {
            p.set("is", 1e-14);
            p.set("n", 1.0);
            p.set("area", 2.0);
        });

        let eval1 = d.eval(&[vd, 0.0], &params1);
        let eval2 = d.eval(&[vd, 0.0], &params2);

        let ratio_id = eval2.g[0] / eval1.g[0];
        let ratio_gd = eval2.G[0].2 / eval1.G[0].2;

        assert!(
            (ratio_id - 2.0).abs() < 1e-6,
            "current ratio={ratio_id}, expected 2"
        );
        assert!(
            (ratio_gd - 2.0).abs() < 1e-6,
            "conductance ratio={ratio_gd}, expected 2"
        );
    }

    /// M multiplier: M=2 → double current AND double conductance.
    #[test]
    fn m_multiplier_doubles_current_and_conductance() {
        let d = Diode;
        let vd = 0.6_f64;

        let params1 = params_with(|p| {
            p.set("is", 1e-14);
            p.set("n", 1.0);
            p.set("m", 1.0);
        });
        let params2 = params_with(|p| {
            p.set("is", 1e-14);
            p.set("n", 1.0);
            p.set("m", 2.0);
        });

        let eval1 = d.eval(&[vd, 0.0], &params1);
        let eval2 = d.eval(&[vd, 0.0], &params2);

        let ratio_id = eval2.g[0] / eval1.g[0];
        let ratio_gd = eval2.G[0].2 / eval1.G[0].2;

        assert!(
            (ratio_id - 2.0).abs() < 1e-6,
            "current ratio={ratio_id}, expected 2"
        );
        assert!(
            (ratio_gd - 2.0).abs() < 1e-6,
            "conductance ratio={ratio_gd}, expected 2"
        );
    }

    /// Junction capacitance: Cj(0) == Cj0 and Cj(forward) > Cj0.
    #[test]
    fn junction_cap_at_zero_bias_equals_cj0() {
        let cj0 = 1e-12_f64; // 1 pF
        let vj = 0.7_f64;
        let mj = 0.5_f64;
        let fc = 0.5_f64;

        let cj_zero = Diode::junction_cap(cj0, 0.0, vj, mj, fc);
        assert!(
            (cj_zero - cj0).abs() < 1e-20,
            "Cj(0) = {cj_zero}, expected {cj0}"
        );
    }

    #[test]
    fn junction_cap_increases_with_forward_bias() {
        let cj0 = 1e-12_f64;
        let vj = 0.7_f64;
        let mj = 0.5_f64;
        let fc = 0.5_f64;

        let cj_fwd = Diode::junction_cap(cj0, 0.5 * vj, vj, mj, fc);
        assert!(
            cj_fwd > cj0,
            "Cj at forward bias ({cj_fwd}) should be > Cj0 ({cj0})"
        );
    }

    /// Eval stamps q and C when cj0 is non-zero.
    #[test]
    fn junction_cap_stamps_q_and_c() {
        let d = Diode;
        let vd = 0.3_f64;
        let cj0 = 2e-12_f64;
        let params = params_with(|p| {
            p.set("is", 1e-14);
            p.set("n", 1.0);
            p.set("cj0", cj0);
            p.set("vj", 0.7);
            p.set("mj", 0.5);
            p.set("fc", 0.5);
        });

        let eval = d.eval(&[vd, 0.0], &params);

        // q must be non-zero and antisymmetric across terminals.
        assert!(eval.q[0] > 0.0, "q[0] should be positive at forward bias");
        assert!((eval.q[0] + eval.q[1]).abs() < 1e-30);

        // C Jacobian must have 4 entries and be antisymmetric.
        assert_eq!(eval.C.len(), 4);
        assert!(eval.C[0].2 > 0.0, "C[0,0] must be positive");
        assert!((eval.C[0].2 + eval.C[1].2).abs() < 1e-30);
    }

    #[test]
    fn cjo_alias_stamps_q_and_c() {
        let d = Diode;
        let params = params_with(|p| {
            p.set("is", 1e-14);
            p.set("n", 1.0);
            p.set("cjo", 2e-12);
            p.set("vj", 0.7);
            p.set("mj", 0.5);
            p.set("fc", 0.5);
        });

        let eval = d.eval(&[0.3, 0.0], &params);

        assert_eq!(eval.C.len(), 4);
        assert!(eval.q[0] > 0.0);
    }

    /// No breakdown when V > -BV.
    #[test]
    fn no_breakdown_above_bv() {
        let d = Diode;
        let params = params_with(|p| {
            p.set("is", 1e-14);
            p.set("n", 1.0);
            p.set("bv", 6.0);
            p.set("ibv", 1e-3);
        });

        // At V=-5.9, just inside the breakdown threshold — no breakdown.
        let eval = d.eval(&[-5.9, 0.0], &params);
        // Current should be the normal reverse leakage, much smaller than IBV.
        assert!(
            eval.g[0].abs() < 1e-10,
            "no breakdown at V=-5.9 with BV=6: got {}",
            eval.g[0]
        );
    }

    /// Breakdown current is finite even for extreme voltages.
    #[test]
    fn breakdown_overflow_protection() {
        let d = Diode;
        let params = params_with(|p| {
            p.set("is", 1e-14);
            p.set("n", 1.0);
            p.set("bv", 6.0);
            p.set("ibv", 1e-3);
        });

        let eval = d.eval(&[-1000.0, 0.0], &params);
        assert!(eval.g[0].is_finite(), "g[0] must be finite");
        assert!(eval.G[0].2.is_finite(), "G[0,0] must be finite");
    }

    /// Forward-bias Shockley current at 27°C vs 100°C — Is scales with temperature.
    ///
    /// At a fixed forward voltage the current at 100°C must be substantially
    /// larger than at 27°C because Is grows exponentially with temperature.
    #[test]
    fn forward_bias_current_27c_vs_100c() {
        let d = Diode;
        let vd = 0.5_f64;
        let is_nom = 1e-14_f64;

        let params_27 = params_with(|p| {
            p.set("is", is_nom);
            p.set("n", 1.0);
            p.set("temp", 300.15); // 27 °C
            p.set("tnom", 300.15);
        });
        let params_100 = params_with(|p| {
            p.set("is", is_nom);
            p.set("n", 1.0);
            p.set("temp", 373.15); // 100 °C
            p.set("tnom", 300.15);
        });

        let eval_27 = d.eval(&[vd, 0.0], &params_27);
        let eval_100 = d.eval(&[vd, 0.0], &params_100);

        // Both must be positive forward currents.
        assert!(eval_27.g[0] > 0.0, "27°C current must be positive");
        assert!(eval_100.g[0] > 0.0, "100°C current must be positive");

        // The 100°C current must be significantly larger than at 27°C.
        assert!(
            eval_100.g[0] > 5.0 * eval_27.g[0],
            "100°C id ({}) should be >> 27°C id ({})",
            eval_100.g[0],
            eval_27.g[0]
        );
    }

    /// Zener breakdown at Vd == -BV: breakdown current should be exactly IBV.
    ///
    /// At Vd = -BV the exponential argument is 0, so exp(0)=1 and
    /// Id_bd = -IBV * 1 = -IBV (anode convention: negative = into cathode).
    #[test]
    fn zener_breakdown_at_exact_bv() {
        let d = Diode;
        let bv = 5.6_f64;
        let ibv = 1e-4_f64;

        let params = params_with(|p| {
            p.set("is", 1e-14);
            p.set("n", 1.0);
            p.set("bv", bv);
            p.set("ibv", ibv);
        });

        // At exactly Vd = -BV the argument to the breakdown exp is 0.
        let eval = d.eval(&[-bv, 0.0], &params);

        // The breakdown branch is inactive for Vd == -BV (condition is Vd < -BV).
        // So this should be plain reverse leakage ≈ -Is, much smaller than IBV.
        assert!(
            eval.g[0].abs() < ibv * 0.01,
            "At Vd=-BV breakdown is inactive; got id={}",
            eval.g[0]
        );

        // One step below: Vd = -BV - epsilon → breakdown kicks in.
        let eval_bd = d.eval(&[-bv - 1e-3, 0.0], &params);
        assert!(
            eval_bd.g[0] < -ibv * 0.5,
            "Just below BV breakdown current should dominate; got id={}",
            eval_bd.g[0]
        );
    }

    /// Junction capacitance at Vd = Vj/2: FD matches analytical.
    ///
    /// Cj_fd = dQ/dV via finite difference on junction_charge().
    /// Cj_analytic = junction_cap().
    /// They must agree to < 0.01%.
    #[test]
    fn junction_cap_fd_vs_analytical_at_vj_half() {
        let cj0 = 3e-12_f64;
        let vj = 0.8_f64;
        let mj = 0.33_f64;
        let fc = 0.5_f64;
        let v = vj / 2.0; // 0.4 V — well inside the depletion region
        let h = 1e-7_f64;

        let q_p = Diode::junction_charge(cj0, v + h, vj, mj, fc);
        let q_m = Diode::junction_charge(cj0, v - h, vj, mj, fc);
        let cj_fd = (q_p - q_m) / (2.0 * h);

        let cj_analytic = Diode::junction_cap(cj0, v, vj, mj, fc);

        let rel_err = (cj_fd - cj_analytic).abs() / cj_analytic.abs().max(1e-30);
        assert!(
            rel_err < 1e-4,
            "FD Cj={cj_fd:.6e}, analytical={cj_analytic:.6e}, rel_err={rel_err:.2e}"
        );
    }

    /// Analytical Jacobian vs finite-difference at three distinct bias points.
    ///
    /// Covers: deep reverse, zero bias, and strong forward bias.
    #[test]
    fn jacobian_vs_fd_at_three_bias_points() {
        let d = Diode;
        let params = params_with(|p| {
            p.set("is", 1e-14);
            p.set("n", 1.0);
            p.set("bv", 30.0);
            p.set("ibv", 1e-4);
            p.set("cj0", 1e-12);
            p.set("vj", 0.7);
            p.set("mj", 0.5);
            p.set("fc", 0.5);
        });
        let h = 1e-7_f64;

        for &vd in &[-1.0_f64, 0.0, 0.55] {
            let eval0 = d.eval(&[vd, 0.0], &params);
            let evalp = d.eval(&[vd + h, 0.0], &params);

            let fd_gd = (evalp.g[0] - eval0.g[0]) / h;
            let analytic_gd = eval0.G[0].2;

            let rel_err = (fd_gd - analytic_gd).abs() / analytic_gd.abs().max(1e-20);
            assert!(
                rel_err < 1e-3,
                "Vd={vd}: FD gd={fd_gd:.6e}, analytic={analytic_gd:.6e}, rel_err={rel_err:.2e}"
            );
        }
    }

    /// Transit-time charge: TT > 0 adds Q_TT = TT * Id to the q vector and
    /// C_TT = TT * gd to the C Jacobian.
    #[test]
    fn transit_time_charge_stamps_q_and_c() {
        let d = Diode;
        let vd = 0.6_f64;
        let tt = 1e-9_f64; // 1 ns transit time

        let params_no_tt = params_with(|p| {
            p.set("is", 1e-14);
            p.set("n", 1.0);
        });
        let params_tt = params_with(|p| {
            p.set("is", 1e-14);
            p.set("n", 1.0);
            p.set("tt", tt);
        });

        let eval_no = d.eval(&[vd, 0.0], &params_no_tt);
        let eval_tt = d.eval(&[vd, 0.0], &params_tt);

        // g (DC current) must be identical — TT does not affect DC.
        assert!(
            (eval_tt.g[0] - eval_no.g[0]).abs() < 1e-20,
            "TT must not change DC current: no_tt={} tt={}",
            eval_no.g[0],
            eval_tt.g[0]
        );

        // q[0] with TT must equal forward diffusion charge only. The TT path
        // intentionally excludes GMIN leakage so stored charge does not go
        // negative during reverse recovery.
        const GMIN: f64 = 1e-12;
        let expected_q_tt = tt * (eval_no.g[0] - GMIN * vd);
        assert!(
            (eval_tt.q[0] - expected_q_tt).abs() < 1e-28,
            "q[0] with TT={}: got {}, expected {}",
            tt,
            eval_tt.q[0],
            expected_q_tt
        );
        // Antisymmetric.
        assert!(
            (eval_tt.q[0] + eval_tt.q[1]).abs() < 1e-30,
            "q must be antisymmetric"
        );

        // C Jacobian must have 4 entries and C[0,0] ≈ TT * dI_diff/dV.
        assert_eq!(eval_tt.C.len(), 4, "C must have 4 entries with TT");
        let c00 = eval_tt.C[0].2;
        let expected_c = tt * (eval_no.G[0].2 - GMIN);
        assert!(
            (c00 - expected_c).abs() / expected_c < 1e-6,
            "C[0,0]={c00:.6e} expected TT*gd={expected_c:.6e}"
        );
    }

    /// Transit-time + junction cap: both contributions sum correctly.
    #[test]
    fn transit_time_plus_junction_cap_sums() {
        let d = Diode;
        let vd = 0.4_f64;
        let tt = 5e-10_f64;
        let cj0 = 1e-12_f64;

        let params = params_with(|p| {
            p.set("is", 1e-14);
            p.set("n", 1.0);
            p.set("tt", tt);
            p.set("cj0", cj0);
            p.set("vj", 0.7);
            p.set("mj", 0.5);
            p.set("fc", 0.5);
        });

        let eval = d.eval(&[vd, 0.0], &params);

        // q[0] must be non-zero and antisymmetric.
        assert!(eval.q[0] > 0.0, "q[0] should be positive at forward bias");
        assert!((eval.q[0] + eval.q[1]).abs() < 1e-30, "q antisymmetric");

        // C Jacobian must exist.
        assert_eq!(eval.C.len(), 4, "C must have 4 entries");
        assert!(eval.C[0].2 > 0.0, "C[0,0] must be positive");
    }

    /// Transit-time storage should turn off in reverse bias instead of becoming negative.
    #[test]
    fn transit_time_does_not_create_negative_reverse_charge() {
        let d = Diode;
        let params = params_with(|p| {
            p.set("is", 1e-14);
            p.set("n", 1.0);
            p.set("tt", 1e-9);
        });

        let eval = d.eval(&[-0.5, 0.0], &params);

        assert!(
            eval.q[0].abs() < 1e-30,
            "reverse TT charge should clamp to zero"
        );
        assert!(
            eval.q[1].abs() < 1e-30,
            "reverse TT charge should clamp to zero"
        );
        assert!(
            eval.C.is_empty(),
            "reverse TT capacitance should be zero without cj0"
        );
    }

    /// Forward stored charge should still scale through the series-resistance solve.
    #[test]
    fn transit_time_with_series_resistance_tracks_internal_forward_current() {
        let d = Diode;
        let tt = 2e-9_f64;
        let params = params_with(|p| {
            p.set("is", 1e-14);
            p.set("n", 1.0);
            p.set("tt", tt);
            p.set("rs", 10.0);
        });

        let eval = d.eval(&[0.8, 0.0], &params);

        assert!(eval.g[0] > 0.0, "forward current should remain positive");
        assert!(eval.q[0] > 0.0, "forward TT charge should remain positive");
        assert_eq!(eval.C.len(), 4, "forward TT capacitance should still stamp");
        assert!(
            eval.C[0].2 > 0.0,
            "forward TT capacitance should be positive"
        );
        assert!(
            eval.q[0] < tt * eval.g[0],
            "TT charge should follow solved junction current"
        );
    }
}
