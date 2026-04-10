//! Accuracy comparison: max abs/rel err, RMSE, and tolerance pass matrix.

use serde::{Deserialize, Serialize};

pub const TOLS: [f64; 4] = [1e-6, 1e-4, 1e-3, 1e-2];

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccuracyReport {
    pub n_signals: usize,
    pub n_points: usize,
    pub max_abs_err: f64,
    pub max_rel_err: f64,
    pub rmse: f64,
    /// pass[i] = true iff max_abs_err <= TOLS[i] OR max_rel_err <= TOLS[i]
    pub pass_matrix: Vec<bool>,
    pub note: String,
}

impl AccuracyReport {
    pub fn empty(note: impl Into<String>) -> Self {
        Self {
            n_signals: 0,
            n_points: 0,
            max_abs_err: f64::NAN,
            max_rel_err: f64::NAN,
            rmse: f64::NAN,
            pass_matrix: vec![false; TOLS.len()],
            note: note.into(),
        }
    }
}

/// Compare two flat samples of the same length.
pub fn compare_samples(pisim: &[f64], ngspice: &[f64]) -> AccuracyReport {
    let n = pisim.len().min(ngspice.len());
    if n == 0 {
        return AccuracyReport::empty("no overlapping samples");
    }

    let mut max_abs = 0.0_f64;
    let mut max_rel = 0.0_f64;
    let mut sum_sq = 0.0_f64;

    pisim.iter().take(n).zip(ngspice.iter().take(n)).for_each(|(a, b)| {
        let d = (a - b).abs();
        if d > max_abs {
            max_abs = d;
        }
        let denom = b.abs().max(1e-12);
        let rel = d / denom;
        if rel > max_rel {
            max_rel = rel;
        }
        sum_sq += d * d;
    });

    let rmse = (sum_sq / n as f64).sqrt();
    let pass_matrix: Vec<bool> = TOLS
        .iter()
        .map(|tol| max_abs <= *tol || max_rel <= *tol)
        .collect();

    AccuracyReport {
        n_signals: 1,
        n_points: n,
        max_abs_err: max_abs,
        max_rel_err: max_rel,
        rmse,
        pass_matrix,
        note: String::new(),
    }
}

/// Compare DC operating-point pairs by name.
pub fn compare_dc_op(
    pisim: &[(String, f64)],
    ngspice: &[(String, f64)],
) -> AccuracyReport {
    let mut a: Vec<f64> = Vec::new();
    let mut b: Vec<f64> = Vec::new();
    let mut matched = 0usize;

    for (name, val) in pisim.iter() {
        let nname = normalize_name(name);
        if let Some((_, nval)) = ngspice
            .iter()
            .find(|(n, _)| normalize_name(n) == nname)
        {
            a.push(*val);
            b.push(*nval);
            matched += 1;
        }
    }

    if matched == 0 {
        return AccuracyReport::empty("no matching DC OP signals");
    }
    let mut r = compare_samples(&a, &b);
    r.n_signals = matched;
    r
}

fn normalize_name(s: &str) -> String {
    let s = s.trim().to_ascii_lowercase();
    // Strip leading "v(" / "i(" so "v(1)" matches "1".
    if let Some(rest) = s.strip_prefix("v(") {
        return rest.trim_end_matches(')').to_string();
    }
    if let Some(rest) = s.strip_prefix("i(") {
        return rest.trim_end_matches(')').to_string();
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identical_samples_pass_all_tols() {
        let a = vec![1.0, 2.0, 3.0];
        let r = compare_samples(&a, &a);
        assert_eq!(r.max_abs_err, 0.0);
        assert!(r.pass_matrix.iter().all(|p| *p));
    }

    #[test]
    fn small_drift_passes_loose_tol() {
        let a = vec![1.0, 2.0, 3.0];
        let b = vec![1.0005, 2.0005, 3.0005];
        let r = compare_samples(&a, &b);
        // Should fail 1e-6 but pass 1e-3, 1e-2.
        assert!(!r.pass_matrix[0]);
        assert!(r.pass_matrix[2] || r.pass_matrix[3]);
    }
}
