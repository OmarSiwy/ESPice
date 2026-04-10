use serde::Deserialize;

/// Tolerance thresholds matching TESTING.md section 7.2.
///
/// Each field is (absolute, relative). A comparison passes if EITHER
/// the absolute error OR the relative error is within threshold.
#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Tolerance {
    pub dc_voltage: (f64, f64),
    pub dc_current: (f64, f64),
    pub tran_voltage: (f64, f64),
    pub tran_timing: f64,
    pub ac_gain_db: f64,
    pub ac_phase_deg: f64,
    pub noise: f64,
    pub hb_harmonics: f64,
    pub sensitivity: f64,
}

impl Default for Tolerance {
    fn default() -> Self {
        Self {
            dc_voltage: (1e-9, 1e-6),
            dc_current: (1e-15, 1e-6),
            tran_voltage: (1e-6, 1e-4),
            tran_timing: 1e-4,
            ac_gain_db: 0.01,
            ac_phase_deg: 0.1,
            noise: 1e-3,
            hb_harmonics: 1e-4,
            sensitivity: 1e-5,
        }
    }
}

impl Tolerance {
    /// Check if two values are within tolerance using (abs, rel) thresholds.
    /// Passes if EITHER absolute error < abs_tol OR relative error < rel_tol.
    pub fn within(actual: f64, expected: f64, abs_tol: f64, rel_tol: f64) -> bool {
        let abs_err = (actual - expected).abs();
        if abs_err < abs_tol {
            return true;
        }
        let denom = expected.abs().max(1e-30);
        let rel_err = abs_err / denom;
        rel_err < rel_tol
    }
}
