use incspice_core::{DeviceKind, ParamMap};
use smallvec::{SmallVec, smallvec};

use crate::device::eval::{DeviceEval, DeviceModel};
use crate::device::waveform::Waveform;

/// Independent current source.
///
/// Pin 0 = positive terminal (current exits), Pin 1 = negative terminal (current enters).
/// Parameters:
///   - `dc`         : DC current (default 0.0)
///   - `ac`         : AC magnitude (consumed by AC analysis)
///   - waveform     : `pulse`, `sin`, `pwl` (see `Waveform::from_params`)
///
/// Convention: current flows FROM pin 0 TO pin 1 (conventional current direction).
/// In KCL terms (current OUT of node = positive):
///   At pin 0: current LEAVES → +I(t)
///   At pin 1: current ENTERS → -I(t)
///
/// This is purely an RHS contribution — no conductance stamps.
#[derive(Debug, Clone, Copy)]
pub struct CurrentSource;

impl CurrentSource {
    /// Compute the source value at the given time `t` from params.
    /// Falls back to `dc` (or 0.0) when no waveform is specified.
    #[inline]
    pub fn value_at(params: &ParamMap, t: f64) -> f64 {
        Waveform::from_params(params).evaluate_at(t)
    }

    /// Core stamp logic shared by all eval variants.
    #[inline]
    fn stamp(i: f64) -> DeviceEval {
        DeviceEval {
            g: smallvec![0.0, 0.0],
            q: smallvec![0.0, 0.0],
            G: SmallVec::new(),
            C: SmallVec::new(),
            // RHS contributions: pin 0 gets +I (out), pin 1 gets -I (in)
            rhs: smallvec![i, -i],
        }
    }
}

impl DeviceModel for CurrentSource {
    fn eval(&self, _voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let idc = Self::value_at(params, 0.0);
        Self::stamp(idc)
    }

    fn eval_at_time(&self, _voltages: &[f64], params: &ParamMap, t: f64) -> DeviceEval {
        let i = Self::value_at(params, t);
        Self::stamp(i)
    }

    fn num_terminals(&self) -> usize {
        2
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::CurrentSource
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_params(idc: f64) -> ParamMap {
        let mut p = ParamMap::new();
        p.set("dc", idc);
        p
    }

    #[test]
    fn isource_rhs_stamps() {
        let is = CurrentSource;
        let params = make_params(1e-3);
        let eval = is.eval(&[0.0, 0.0], &params);

        assert_eq!(eval.rhs.len(), 2);
        assert!((eval.rhs[0] - 1e-3).abs() < 1e-15); // +Idc at pin 0 (out)
        assert!((eval.rhs[1] + 1e-3).abs() < 1e-15); // -Idc at pin 1 (in)
    }

    #[test]
    fn isource_no_conductance() {
        let is = CurrentSource;
        let params = make_params(5.0);
        let eval = is.eval(&[10.0, 0.0], &params);

        assert!(eval.G.is_empty());
        assert!(eval.C.is_empty());
    }

    #[test]
    fn isource_no_branch() {
        let is = CurrentSource;
        assert!(!is.needs_branch());
    }

    #[test]
    fn isource_zero_current() {
        let is = CurrentSource;
        let params = make_params(0.0);
        let eval = is.eval(&[5.0, 0.0], &params);

        assert!((eval.rhs[0]).abs() < 1e-15);
        assert!((eval.rhs[1]).abs() < 1e-15);
    }

    #[test]
    fn isource_negative_current() {
        let is = CurrentSource;
        let params = make_params(-2.0);
        let eval = is.eval(&[0.0, 0.0], &params);

        assert!((eval.rhs[0] + 2.0).abs() < 1e-15);
        assert!((eval.rhs[1] - 2.0).abs() < 1e-15);
    }

    #[test]
    fn isource_voltage_independent() {
        let is = CurrentSource;
        let params = make_params(1e-3);
        let eval1 = is.eval(&[0.0, 0.0], &params);
        let eval2 = is.eval(&[100.0, -50.0], &params);

        assert!((eval1.rhs[0] - eval2.rhs[0]).abs() < 1e-15);
        assert!((eval1.rhs[1] - eval2.rhs[1]).abs() < 1e-15);
    }

    #[test]
    fn isource_sin_waveform_t0() {
        // SIN(vo=0 va=1 freq=1k td=0 theta=0)  →  at t=0 returns 0
        let mut p = ParamMap::new();
        p.set("waveform_kind", 2.0);
        p.set("sin_vo", 0.0);
        p.set("sin_va", 1.0);
        p.set("sin_freq", 1000.0);
        p.set("sin_td", 0.0);
        p.set("sin_theta", 0.0);

        let is = CurrentSource;
        let eval = is.eval(&[0.0, 0.0], &p);
        assert!(eval.rhs[0].abs() < 1e-15);
    }

    // ── Additional CurrentSource tests ────────────────────────────────────────

    /// RHS antisymmetry: rhs[0] + rhs[1] == 0 always.
    #[test]
    fn isource_rhs_antisymmetric() {
        let is = CurrentSource;
        for &idc in &[-10.0_f64, -1e-3, 0.0, 1e-6, 5.0] {
            let params = make_params(idc);
            let eval = is.eval(&[0.0, 0.0], &params);
            assert!(
                (eval.rhs[0] + eval.rhs[1]).abs() < 1e-15,
                "rhs not antisymmetric at idc={idc}: {} + {}", eval.rhs[0], eval.rhs[1]
            );
        }
    }

    /// g vector is always zero (no resistive current contribution).
    #[test]
    fn isource_g_vector_always_zero() {
        let is = CurrentSource;
        let params = make_params(1.0);
        let eval = is.eval(&[100.0, -50.0], &params);
        assert!(eval.g[0].abs() < 1e-30, "g[0] must be 0");
        assert!(eval.g[1].abs() < 1e-30, "g[1] must be 0");
    }

    /// q vector is always zero for a current source.
    #[test]
    fn isource_q_vector_always_zero() {
        let is = CurrentSource;
        let params = make_params(1e-3);
        let eval = is.eval(&[5.0, 0.0], &params);
        assert!(eval.q[0].abs() < 1e-30, "q[0] must be 0");
        assert!(eval.q[1].abs() < 1e-30, "q[1] must be 0");
    }

    /// DC default: no 'dc' param → zero current.
    #[test]
    fn isource_default_dc_zero() {
        let is = CurrentSource;
        let p = ParamMap::new();
        let eval = is.eval(&[5.0, 0.0], &p);
        assert!(eval.rhs[0].abs() < 1e-30, "default idc=0");
        assert!(eval.rhs[1].abs() < 1e-30, "default idc=0");
    }

    /// eval_at_time with DC source gives same result as eval.
    #[test]
    fn isource_dc_eval_at_time_equals_eval() {
        let is = CurrentSource;
        let params = make_params(2e-3);
        let v = [1.0_f64, 0.0];
        let eval0 = is.eval(&v, &params);
        let eval_t = is.eval_at_time(&v, &params, 50e-6);
        assert!(
            (eval0.rhs[0] - eval_t.rhs[0]).abs() < 1e-15,
            "DC current source should be time-invariant"
        );
    }

    /// Large and small current values are handled correctly.
    #[test]
    fn isource_various_current_magnitudes() {
        let is = CurrentSource;
        for &idc in &[1e-12_f64, 1e-6, 1e-3, 1.0, 1e3] {
            let params = make_params(idc);
            let eval = is.eval(&[0.0, 0.0], &params);
            assert!(
                (eval.rhs[0] - idc).abs() < 1e-15 * idc.max(1.0),
                "idc={idc}: rhs[0]={}", eval.rhs[0]
            );
        }
    }
}
