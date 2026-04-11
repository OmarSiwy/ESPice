//! Uniform RC Transmission Line (`U` element).
//!
//! Expanded at parse time into LUMPS series-R + shunt-C segments.
//!
//! ## Syntax
//! ```text
//! U<name> n+ n- n_ref <model_name> [L=<len>] [LUMPS=<n>]
//! ```
//!
//! ## Parameters
//!
//! | Key         | Default | Description                        |
//! |-------------|---------|-------------------------------------|
//! | `r_per_len` | 1.0     | Series resistance per unit length (Ω/m) |
//! | `c_per_len` | 1e-12   | Shunt capacitance per unit length (F/m) |
//! | `length`    | 1.0     | Total line length (m)               |
//! | `lumps`     | 3       | Number of RC segments               |

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
    /// Stamp a single-segment equivalent: series resistor between pins 0 and 1,
    /// shunt capacitor from pin 1 to pin 2 (reference).
    ///
    /// The full URC expansion is handled by the parser/build_circuit step which
    /// injects individual `Resistor` and `Capacitor` elements; this impl
    /// serves as a fallback DC stamp so the model registry stays consistent.
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        use smallvec::smallvec;

        let lumps = params.get_or("lumps", 3.0) as usize;
        let n = lumps.max(1);
        let r_per_len = params.get_or("r_per_len", self.r_per_len);
        let length = params.get_or("length", self.length);
        let r_seg = (r_per_len * length / n as f64).max(1e-12);
        let g_series = 1.0 / r_seg;

        let vp = voltages.first().copied().unwrap_or(0.0);
        let vn = voltages.get(1).copied().unwrap_or(0.0);

        let i = (vp - vn) * g_series;

        DeviceEval {
            g: smallvec![i, -i],
            q: smallvec![],
            G: smallvec![(0, 0, g_series), (0, 1, -g_series), (1, 0, -g_series), (1, 1, g_series)],
            C: smallvec![],
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
}
