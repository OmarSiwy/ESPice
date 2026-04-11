//! PORT element: S-parameter excitation port (HSPICE).
//!
//! Models a Thevenin equivalent: voltage source `Vs` in series with a
//! reference impedance `Z0` (default 50 Ω).
//!
//! ## Syntax
//! ```text
//! PORT<name> n+ n- [Z0=50] [DC=0] [PORT=<n>]
//! ```
//!
//! ## MNA formulation
//!
//! The Thevenin equivalent has one branch current variable `I_b`:
//!
//! ```text
//!   KCL at n+:      +I_b           = 0
//!   KCL at n-:      -I_b           = 0
//!   Branch eq:  V(n+) - V(n-) - Z0·I_b - Vs  = 0
//! ```
//!
//! Jacobian (columns: n+, n-, branch):
//! ```text
//!   [ 0,  0, +1 ]   ← row n+
//!   [ 0,  0, -1 ]   ← row n-
//!   [+1, -1, -Z0]   ← branch row
//! ```
//!
//! ## Parameters
//!
//! | Key       | Default | Description                               |
//! |-----------|---------|-------------------------------------------|
//! | `z0`      | 50.0    | Reference impedance (Ω)                   |
//! | `dc`      | 0.0     | DC source value (V)                       |
//! | `port_num`| 1       | 1-based port index for S-parameter analysis |
//! | `ac`      | 1.0     | AC excitation amplitude (V) — used by AC analysis |

use smallvec::smallvec;
use bigospice_core::{DeviceKind, ParamMap};
use crate::eval::{DeviceEval, DeviceModel};

/// PORT element model.
///
/// State-free; all configuration lives in the `ParamMap`.
#[derive(Debug, Clone, Copy)]
pub struct Port;

impl Port {
    /// Resolve the source value and Z0 from params.
    #[inline]
    fn resolve(params: &ParamMap, t: f64) -> (f64, f64) {
        let z0 = params.get_or("z0", 50.0).max(0.0);
        let vs = if t == 0.0 {
            params.get_or("dc", 0.0)
        } else {
            params.get_or("dc", 0.0)
        };
        (vs, z0)
    }

    #[inline]
    fn stamp(voltages: &[f64], branch_current: f64, vs: f64, z0: f64) -> DeviceEval {
        let v0 = voltages.first().copied().unwrap_or(0.0);
        let v1 = voltages.get(1).copied().unwrap_or(0.0);

        // g residuals:
        //   row 0 (n+): +I_b
        //   row 1 (n-): -I_b
        //   row 2 (branch): V(n+) - V(n-) - Z0*I_b  (Vs goes to RHS)
        DeviceEval {
            g: smallvec![branch_current, -branch_current, v0 - v1 - z0 * branch_current],
            q: smallvec![0.0, 0.0, 0.0],
            G: smallvec![
                (0, 2,  1.0),
                (1, 2, -1.0),
                (2, 0,  1.0),
                (2, 1, -1.0),
                (2, 2, -z0),
            ],
            C: smallvec![],
            rhs: smallvec![vs],
        }
    }
}

impl DeviceModel for Port {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        self.eval_with_branch(voltages, 0.0, params)
    }

    fn eval_with_branch(
        &self,
        voltages: &[f64],
        branch_current: f64,
        params: &ParamMap,
    ) -> DeviceEval {
        let (vs, z0) = Self::resolve(params, 0.0);
        Self::stamp(voltages, branch_current, vs, z0)
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
        let (vs, z0) = Self::resolve(params, t);
        Self::stamp(voltages, branch_current, vs, z0)
    }

    fn num_terminals(&self) -> usize {
        2  // n+, n-
    }

    fn needs_branch(&self) -> bool {
        true  // requires a branch current variable in MNA
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::Port
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_params(z0: f64, dc: f64) -> ParamMap {
        let mut p = ParamMap::new();
        p.set("z0", z0);
        p.set("dc", dc);
        p
    }

    #[test]
    fn port_kind_and_terminals() {
        assert_eq!(Port.kind(), DeviceKind::Port);
        assert_eq!(Port.num_terminals(), 2);
        assert!(Port.needs_branch());
    }

    #[test]
    fn port_dc_zero_no_excitation() {
        let p = make_params(50.0, 0.0);
        let eval = Port.eval_with_branch(&[0.0, 0.0], 0.0, &p);
        // Zero source, zero voltages, zero branch current → all residuals zero.
        assert!(eval.g[0].abs() < 1e-15);
        assert!(eval.g[1].abs() < 1e-15);
        assert!(eval.g[2].abs() < 1e-15);
        assert!((eval.rhs[0]).abs() < 1e-15);
    }

    #[test]
    fn port_dc_source_appears_in_rhs() {
        let p = make_params(50.0, 1.0);
        let eval = Port.eval_with_branch(&[0.0, 0.0], 0.0, &p);
        assert!((eval.rhs[0] - 1.0).abs() < 1e-15);
    }

    #[test]
    fn port_z0_in_jacobian() {
        let p = make_params(75.0, 0.0);
        let eval = Port.eval_with_branch(&[0.0, 0.0], 0.0, &p);
        // Branch-row, branch-col entry should be -Z0 = -75.
        let branch_diag = eval.G.iter()
            .find(|&&(r, c, _)| r == 2 && c == 2)
            .map(|&(_, _, v)| v);
        assert_eq!(branch_diag, Some(-75.0));
    }

    #[test]
    fn port_branch_current_propagates() {
        let p = make_params(50.0, 0.0);
        let eval = Port.eval_with_branch(&[0.0, 0.0], 2e-3, &p);
        // KCL rows: g[0] = +I_b, g[1] = -I_b.
        assert!((eval.g[0] - 2e-3).abs() < 1e-18);
        assert!((eval.g[1] + 2e-3).abs() < 1e-18);
    }
}
