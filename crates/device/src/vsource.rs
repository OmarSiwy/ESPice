use smallvec::{SmallVec, smallvec};
use pisim_core::{DeviceKind, ParamMap};

use crate::eval::{DeviceEval, DeviceModel};
use crate::waveform::Waveform;

/// Independent voltage source (MNA formulation).
///
/// Pin 0 = V+ (positive), Pin 1 = V- (negative).
/// Branch index = 2 (branch current variable).
///
/// Parameters supported:
///   - `dc`           : DC voltage (default 0.0)
///   - `ac`           : AC magnitude (consumed by AC analysis)
///   - waveform       : `pulse`, `sin`, or `pwl` encoded as a set of
///                      named scalar params under reserved keys
///                      (see `Waveform::from_params`).
///
/// MNA stamps:
///   KCL at pin 0: ... + I_branch = 0
///   KCL at pin 1: ... - I_branch = 0
///   Branch equation: V0 - V1 = V(t)  →  residual: V0 - V1 - V(t) = 0
///
/// g[0] = +I_branch, g[1] = -I_branch, g[2] = V0 - V1
/// rhs[0] = V(t) (for branch equation)
/// G: (0,2,+1), (1,2,-1), (2,0,+1), (2,1,-1)
#[derive(Debug, Clone, Copy)]
pub struct VoltageSource;

impl VoltageSource {
    /// Compute the source value at the given time `t` from params.
    /// Falls back to `dc` (or 0.0) when no waveform is specified.
    #[inline]
    pub fn value_at(params: &ParamMap, t: f64) -> f64 {
        Waveform::from_params(params).evaluate_at(t)
    }

    /// Core stamp logic shared by all eval variants.
    #[inline]
    fn stamp(voltages: &[f64], branch_current: f64, vsource: f64) -> DeviceEval {
        let v0 = voltages[0];
        let v1 = voltages[1];
        DeviceEval {
            g: smallvec![branch_current, -branch_current, v0 - v1],
            q: smallvec![0.0, 0.0, 0.0],
            G: smallvec![
                (0, 2, 1.0),
                (1, 2, -1.0),
                (2, 0, 1.0),
                (2, 1, -1.0),
            ],
            C: SmallVec::new(),
            rhs: smallvec![vsource],
        }
    }
}

impl DeviceModel for VoltageSource {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        self.eval_with_branch(voltages, 0.0, params)
    }

    fn eval_with_branch(
        &self,
        voltages: &[f64],
        branch_current: f64,
        params: &ParamMap,
    ) -> DeviceEval {
        // Evaluate waveform at t=0 (DC operating point / compatibility path).
        let vdc = Self::value_at(params, 0.0);
        Self::stamp(voltages, branch_current, vdc)
    }

    fn eval_at_time(&self, voltages: &[f64], params: &ParamMap, t: f64) -> DeviceEval {
        self.eval_with_branch_at_time(voltages, 0.0, params, t)
    }

    fn eval_with_branch_at_time(
        &self,
        voltages: &[f64],
        branch_current: f64,
        params: &ParamMap,
        t: f64,
    ) -> DeviceEval {
        let v = Self::value_at(params, t);
        Self::stamp(voltages, branch_current, v)
    }

    fn num_terminals(&self) -> usize {
        2
    }

    fn needs_branch(&self) -> bool {
        true
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::VoltageSource
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_params(vdc: f64) -> ParamMap {
        let mut p = ParamMap::new();
        p.set("dc", vdc);
        p
    }

    #[test]
    fn vsource_stamp_pattern() {
        let vs = VoltageSource;
        let params = make_params(5.0);
        let eval = vs.eval_with_branch(&[5.0, 0.0], 0.001, &params);

        // g: [I_br, -I_br, V0-V1]
        assert!((eval.g[0] - 0.001).abs() < 1e-15);
        assert!((eval.g[1] + 0.001).abs() < 1e-15);
        assert!((eval.g[2] - 5.0).abs() < 1e-15);

        // rhs: [Vdc]
        assert_eq!(eval.rhs.len(), 1);
        assert!((eval.rhs[0] - 5.0).abs() < 1e-15);
    }

    #[test]
    fn vsource_jacobian_structure() {
        let vs = VoltageSource;
        let params = make_params(3.3);
        let eval = vs.eval_with_branch(&[3.3, 0.0], 0.0, &params);

        assert_eq!(eval.G.len(), 4);
        assert_eq!(eval.G[0], (0, 2, 1.0));
        assert_eq!(eval.G[1], (1, 2, -1.0));
        assert_eq!(eval.G[2], (2, 0, 1.0));
        assert_eq!(eval.G[3], (2, 1, -1.0));
    }

    #[test]
    fn vsource_needs_branch() {
        let vs = VoltageSource;
        assert!(vs.needs_branch());
    }

    #[test]
    fn vsource_zero_voltage() {
        let vs = VoltageSource;
        let params = make_params(0.0);
        let eval = vs.eval_with_branch(&[0.0, 0.0], 0.5, &params);

        assert!((eval.g[0] - 0.5).abs() < 1e-15);
        assert!((eval.rhs[0]).abs() < 1e-15);
    }

    #[test]
    fn vsource_negative_voltage() {
        let vs = VoltageSource;
        let params = make_params(-12.0);
        let eval = vs.eval_with_branch(&[-12.0, 0.0], 0.0, &params);

        assert!((eval.rhs[0] + 12.0).abs() < 1e-15);
        assert!((eval.g[2] + 12.0).abs() < 1e-15);
    }

    #[test]
    fn vsource_finite_difference() {
        let vs = VoltageSource;
        let params = make_params(5.0);
        let h = 1e-7;
        let i_br = 0.01;
        let v = [5.0, 0.0];

        let eval0 = vs.eval_with_branch(&v, i_br, &params);

        // Perturb V0
        let eval_pv0 = vs.eval_with_branch(&[v[0] + h, v[1]], i_br, &params);
        let dg2_dv0 = (eval_pv0.g[2] - eval0.g[2]) / h;
        assert!((dg2_dv0 - 1.0).abs() < 1e-6);

        // Perturb I_branch
        let eval_pi = vs.eval_with_branch(&v, i_br + h, &params);
        let dg0_di = (eval_pi.g[0] - eval0.g[0]) / h;
        assert!((dg0_di - 1.0).abs() < 1e-6);
    }

    #[test]
    fn vsource_pulse_at_t0() {
        // PULSE(v1=0 v2=5 td=1u tr=1n tf=1n pw=10u per=20u)
        // At t=0 (before td), value = v1 = 0
        let mut p = ParamMap::new();
        p.set("waveform_kind", 1.0);
        p.set("pulse_v1", 0.0);
        p.set("pulse_v2", 5.0);
        p.set("pulse_td", 1e-6);
        p.set("pulse_tr", 1e-9);
        p.set("pulse_tf", 1e-9);
        p.set("pulse_pw", 10e-6);
        p.set("pulse_per", 20e-6);

        let vs = VoltageSource;
        let eval = vs.eval_with_branch(&[0.0, 0.0], 0.0, &p);
        assert!((eval.rhs[0]).abs() < 1e-15);
    }
}
