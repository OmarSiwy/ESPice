//! Uniform RC Transmission Line (`U` element).
//!
//! Expanded at parse time into LUMPS series-R + shunt-C segments.
//!
//! ## Syntax
//! ```text
//! U<name> n+ n- n_ref <model_name> [L=<len>] [LUMPS=<n>]
//! ```
//!
//! ## Model-card parameters
//!
//! | Key         | Alias     | Default | Description                        |
//! |-------------|-----------|---------|-------------------------------------|
//! | `r_per_len` | `ro`      | 1.0     | Series resistance per unit length (Ω/m) |
//! | `c_per_len` | `co`      | 1e-12   | Shunt capacitance per unit length (F/m) |
//! | `length`    | `l`       | 1.0     | Total line length (m)               |
//! | `lumps`     |           | 3       | Number of RC segments               |
//! | `k`         |           | 1.5     | Propagation constant (unused in stamp; reserved) |
//! | `fmax`      |           | 1e9     | Max frequency (unused in stamp; reserved) |

use bigospice_core::{DeviceKind, ParamMap};
use crate::eval::{DeviceEval, DeviceModel};

/// Uniform RC transmission line device model.
///
/// State-free; the segment expansion is performed at parse time.
/// The `DeviceModel` impl stamps a single segment's R and C contribution
/// (the stamper iterates over all segments produced by [`Urc::segments`]).
#[derive(Debug, Clone, Copy)]
pub struct Urc {
    pub r_per_len: f64,   // Ω/m
    pub c_per_len: f64,   // F/m
    pub length: f64,      // m
    pub lumps: usize,     // default 3
}

/// One RC segment produced by the URC expansion.
#[derive(Debug, Clone, Copy)]
pub struct RcSegment {
    pub r: f64,
    pub c: f64,
}

impl Urc {
    /// Expand the URC into `lumps` equal RC segments.
    pub fn segments(&self) -> Vec<RcSegment> {
        let n = self.lumps.max(1);
        let r_seg = self.r_per_len * self.length / n as f64;
        let c_seg = self.c_per_len * self.length / n as f64;
        vec![RcSegment { r: r_seg, c: c_seg }; n]
    }

    /// Resolve parameters from a device [`ParamMap`], accepting both
    /// canonical names (`r_per_len`, `c_per_len`, `length`) and
    /// standard SPICE model-card aliases (`ro`, `co`, `l`).
    fn resolve(params: &ParamMap) -> (f64, f64, f64, usize) {
        let r_per_len = params.get_or("r_per_len",
            params.get_or("ro", 1.0));
        let c_per_len = params.get_or("c_per_len",
            params.get_or("co", 1e-12));
        let length = params.get_or("length",
            params.get_or("l", 1.0));
        let lumps = params.get_or("lumps", 3.0) as usize;
        (r_per_len, c_per_len, length, lumps.max(1))
    }
}

impl Default for Urc {
    fn default() -> Self {
        Self {
            r_per_len: 1.0,
            c_per_len: 1e-12,
            length: 1.0,
            lumps: 3,
        }
    }
}

impl DeviceModel for Urc {
    /// Stamp a lumped RC equivalent between the three terminals.
    ///
    /// Pin 0 = n+ (input), Pin 1 = n- (output), Pin 2 = n_ref (reference/ground).
    ///
    /// DC stamp: total series resistance `R_tot = r_per_len * length` between
    /// pins 0 and 1, plus shunt conductance at each end (from the shunt-C
    /// `G_shunt = 0` at DC — capacitors are open at DC, so only the series R
    /// path is stamped for DC).
    ///
    /// Transient stamp (via `C` Jacobian): total shunt capacitance
    /// `C_tot = c_per_len * length` split equally between pin-0-to-ref and
    /// pin-1-to-ref as `C_tot/2` each.
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        use smallvec::smallvec;

        let (r_per_len, c_per_len, length, lumps) = Self::resolve(params);
        let n = lumps;
        let r_seg = (r_per_len * length / n as f64).max(1e-12);
        let g_series = 1.0 / r_seg;

        // For the DC stamp we collapse the N-segment RC ladder into a single
        // series resistor R_tot between pin 0 and pin 1. This is exact at DC
        // (capacitors are open circuits).
        let r_tot = r_seg * n as f64;
        let g_tot = 1.0 / r_tot.max(1e-12);

        let vp = voltages.first().copied().unwrap_or(0.0);
        let vn = voltages.get(1).copied().unwrap_or(0.0);
        let vref = voltages.get(2).copied().unwrap_or(0.0);

        let i_series = (vp - vn) * g_tot;

        // Total shunt capacitance, split equally between the two ports
        // relative to the reference node (pin 2).
        let c_tot = c_per_len * length;
        let c_half = c_tot * 0.5;

        // Charge: q = C * V  for each shunt cap
        let q_p  = c_half * (vp - vref);
        let q_n  = c_half * (vn - vref);

        DeviceEval {
            // DC residuals (KCL): series current between pin 0 and pin 1
            g: smallvec![i_series, -i_series, 0.0],
            // Reactive charges: shunt C/2 at each port to reference
            q: smallvec![q_p, q_n, -(q_p + q_n)],
            // DC Jacobian: series conductance between pins 0 and 1
            #[allow(non_snake_case)]
            G: smallvec![
                (0, 0, g_tot),
                (0, 1, -g_tot),
                (1, 0, -g_tot),
                (1, 1, g_tot),
            ],
            // Reactive Jacobian: dq/dV for shunt capacitors
            C: smallvec![
                (0, 0, c_half),    // dq[0]/dV(pin0)
                (0, 2, -c_half),   // dq[0]/dV(ref)
                (1, 1, c_half),    // dq[1]/dV(pin1)
                (1, 2, -c_half),   // dq[1]/dV(ref)
                (2, 0, -c_half),   // dq[2]/dV(pin0)  (KCL at ref)
                (2, 1, -c_half),   // dq[2]/dV(pin1)
                (2, 2, c_half + c_half),  // dq[2]/dV(ref)
            ],
            rhs: smallvec![],
        }
    }

    fn num_terminals(&self) -> usize {
        3  // n+, n-, n_ref
    }

    fn needs_branch(&self) -> bool {
        false
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::Urc
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urc_segments_default() {
        let u = Urc::default();
        let segs = u.segments();
        assert_eq!(segs.len(), 3);
        let total_r: f64 = segs.iter().map(|s| s.r).sum();
        assert!((total_r - u.r_per_len * u.length).abs() < 1e-15);
    }

    #[test]
    fn urc_segments_custom() {
        let u = Urc { r_per_len: 100.0, c_per_len: 1e-9, length: 0.5, lumps: 5 };
        let segs = u.segments();
        assert_eq!(segs.len(), 5);
        let total_r: f64 = segs.iter().map(|s| s.r).sum();
        let total_c: f64 = segs.iter().map(|s| s.c).sum();
        assert!((total_r - 50.0).abs() < 1e-12);
        assert!((total_c - 5e-10).abs() < 1e-25);
    }

    #[test]
    fn urc_kind() {
        let u = Urc::default();
        assert_eq!(u.kind(), DeviceKind::Urc);
        assert!(!u.needs_branch());
        assert_eq!(u.num_terminals(), 3);
    }

    #[test]
    fn urc_ro_co_aliases() {
        let u = Urc::default();
        let mut p = ParamMap::new();
        p.set("ro", 1000.0);
        p.set("co", 1e-13);
        p.set("l", 1e-3);
        p.set("lumps", 3.0);
        let eval = u.eval(&[1.0, 0.0, 0.0], &p);
        // R_tot = 1000 * 1e-3 = 1.0 Ω → g_tot = 1.0
        // I = (1.0 - 0.0) * 1.0 = 1.0
        assert!((eval.g[0] - 1.0).abs() < 1e-12, "g[0]={}", eval.g[0]);
        assert!((eval.g[1] + 1.0).abs() < 1e-12, "g[1]={}", eval.g[1]);
        // C_tot = 1e-13 * 1e-3 = 1e-16 → c_half = 5e-17
        // q[0] = c_half * (1.0 - 0.0) = 5e-17
        assert!((eval.q[0] - 5e-17).abs() < 1e-30, "q[0]={}", eval.q[0]);
    }

    #[test]
    fn urc_dc_kcl() {
        let u = Urc::default();
        let mut p = ParamMap::new();
        p.set("ro", 100.0);
        p.set("co", 1e-12);
        p.set("l", 1.0);
        let eval = u.eval(&[2.0, 1.0, 0.0], &p);
        let sum: f64 = eval.g.iter().sum();
        assert!(sum.abs() < 1e-20, "DC KCL violated: sum={sum}");
    }
}
