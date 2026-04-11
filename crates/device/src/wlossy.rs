//! W-element: frequency-domain lossy transmission line (Xyce).
//!
//! Full tabulated S/Y/Z-parameter interpolation is future work.
//! This stub falls back to LTRA with placeholder R/L/C values so
//! netlists parse and produce non-NaN simulation results.
//!
//! ## Syntax
//! ```text
//! W<name> n+ n- <model> [RLGC_FILE=<path>] [L=<len>]
//! ```
//!
//! ## Parameters
//!
//! | Key    | Default | Description                              |
//! |--------|---------|------------------------------------------|
//! | `r`    | 1.0     | Fallback series resistance (Ω/m)         |
//! | `l`    | 1e-9    | Fallback series inductance (H/m)         |
//! | `c`    | 1e-12   | Fallback shunt capacitance (F/m)         |
//! | `len`  | 1.0     | Total line length (m)                    |

use bigospice_core::{DeviceKind, ParamMap};
use crate::eval::{DeviceEval, DeviceModel};
use crate::ltra::Ltra;

/// Which S/Y/Z parameter type the tabulated data file contains.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParamKind {
    S,
    Y,
    Z,
}

impl Default for ParamKind {
    fn default() -> Self {
        Self::S
    }
}

/// W-element: frequency-domain lossy transmission line (Xyce stub).
///
/// Until tabulated S/Y/Z-parameter interpolation is implemented this
/// delegates all stamping to [`Ltra`] using the fallback RLGC parameters.
///
/// `Copy`-able so it can live inside [`crate::DeviceDispatch`] which is
/// `#[derive(Copy)]`.  The RLGC parameter file path (if any) is stored
/// separately in the instance `ParamMap` under the key `rlgc_file_idx`
/// (an index into the netlist's string table — future work).
#[derive(Debug, Clone, Copy)]
pub struct WLossy {
    pub n_ports: usize,
    /// Whether a tabulated parameter file was specified on the element line.
    /// The actual path lives in the instance `ParamMap` (future work).
    pub has_param_file: bool,
    pub param_kind: ParamKind,
    /// Fallback R (Ω/m) — used until tabulated interpolation is implemented.
    pub r: f64,
    /// Fallback L (H/m).
    pub l: f64,
    /// Fallback C (F/m).
    pub c: f64,
    pub length: f64,
}

impl Default for WLossy {
    fn default() -> Self {
        Self {
            n_ports: 2,
            has_param_file: false,
            param_kind: ParamKind::default(),
            r: 1.0,
            l: 1e-9,
            c: 1e-12,
            length: 1.0,
        }
    }
}

impl DeviceModel for WLossy {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        // Delegate to LTRA with the fallback RLGC values.
        // Build a synthetic ParamMap that fills in any missing keys.
        let mut merged = params.clone();
        if merged.get("r").is_none() {
            merged.set("r", self.r);
        }
        if merged.get("l").is_none() {
            merged.set("l", self.l);
        }
        if merged.get("g").is_none() {
            merged.set("g", 0.0);
        }
        if merged.get("c").is_none() {
            merged.set("c", self.c);
        }
        if merged.get("len").is_none() {
            merged.set("len", self.length);
        }
        Ltra.eval(voltages, &merged)
    }

    fn eval_with_branch(
        &self,
        voltages: &[f64],
        branch_current: f64,
        params: &ParamMap,
    ) -> DeviceEval {
        let mut merged = params.clone();
        if merged.get("r").is_none() {
            merged.set("r", self.r);
        }
        if merged.get("l").is_none() {
            merged.set("l", self.l);
        }
        if merged.get("g").is_none() {
            merged.set("g", 0.0);
        }
        if merged.get("c").is_none() {
            merged.set("c", self.c);
        }
        if merged.get("len").is_none() {
            merged.set("len", self.length);
        }
        Ltra.eval_with_branch(voltages, branch_current, &merged)
    }

    fn num_terminals(&self) -> usize {
        4  // in+, in-, out+, out-  (same as LTRA)
    }

    fn needs_branch(&self) -> bool {
        false
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::Wlossy
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wlossy_kind_and_terminals() {
        let w = WLossy::default();
        assert_eq!(w.kind(), DeviceKind::Wlossy);
        assert_eq!(w.num_terminals(), 4);
        assert!(!w.needs_branch());
    }

    #[test]
    fn wlossy_delegates_to_ltra() {
        let w = WLossy::default();
        let params = ParamMap::new();
        // Should not panic and should return a non-empty Jacobian.
        let eval = w.eval(&[1.0, 0.0, 0.0, 0.0], &params);
        assert!(!eval.G.is_empty());
    }

    #[test]
    fn wlossy_param_override() {
        // Explicit params should override the defaults.
        let w = WLossy::default();
        let mut params = ParamMap::new();
        params.set("r", 10.0);
        params.set("len", 2.0);
        let eval = w.eval(&[1.0, 0.0, 0.0, 0.0], &params);
        // g[0] = I_series = 1V / (10*2) = 0.05 A
        assert!((eval.g[0] - 0.05).abs() < 1e-10, "g[0]={}", eval.g[0]);
    }
}
