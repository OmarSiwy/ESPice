use crate::tolerance::Tolerance;

#[derive(Debug, Clone)]
pub struct SignalMismatch {
    pub signal_name: String,
    pub index: usize,
    pub expected: f64,
    pub actual: f64,
    pub abs_error: f64,
    pub rel_error: f64,
}

#[derive(Debug, Clone)]
pub struct CompareResult {
    pub passed: bool,
    pub max_abs_error: f64,
    pub max_rel_error: f64,
    pub total_points: usize,
    pub failing_points: Vec<SignalMismatch>,
}

/// Compare two vectors of named (signal_name, value) pairs for DC results.
pub fn compare_dc_values(
    actual: &[(String, f64)],
    expected: &[(String, f64)],
    tol: &Tolerance,
    is_current: bool,
) -> CompareResult {
    let (abs_tol, rel_tol) = if is_current {
        tol.dc_current
    } else {
        tol.dc_voltage
    };

    let mut max_abs = 0.0_f64;
    let mut max_rel = 0.0_f64;
    let mut failing = Vec::new();

    for (i, (name, exp_val)) in expected.iter().enumerate() {
        let act_val = actual
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| *v)
            .unwrap_or(f64::NAN);

        let abs_err = (act_val - exp_val).abs();
        let denom = exp_val.abs().max(1e-30);
        let rel_err = abs_err / denom;

        max_abs = max_abs.max(abs_err);
        max_rel = max_rel.max(rel_err);

        if !Tolerance::within(act_val, *exp_val, abs_tol, rel_tol) {
            failing.push(SignalMismatch {
                signal_name: name.clone(),
                index: i,
                expected: *exp_val,
                actual: act_val,
                abs_error: abs_err,
                rel_error: rel_err,
            });
        }
    }

    CompareResult {
        passed: failing.is_empty(),
        max_abs_error: max_abs,
        max_rel_error: max_rel,
        total_points: expected.len(),
        failing_points: failing,
    }
}

/// Compare two 2D waveform arrays (e.g., transient or sweep results).
pub fn compare_waveforms(
    actual: &[Vec<f64>],
    expected: &[Vec<f64>],
    signal_names: &[String],
    abs_tol: f64,
    rel_tol: f64,
) -> CompareResult {
    let mut max_abs = 0.0_f64;
    let mut max_rel = 0.0_f64;
    let mut failing = Vec::new();
    let mut total = 0;

    let len = actual.len().min(expected.len());
    for t in 0..len {
        let sig_len = actual[t].len().min(expected[t].len());
        for s in 0..sig_len {
            total += 1;
            let act = actual[t][s];
            let exp = expected[t][s];
            let abs_err = (act - exp).abs();
            let denom = exp.abs().max(1e-30);
            let rel_err = abs_err / denom;

            max_abs = max_abs.max(abs_err);
            max_rel = max_rel.max(rel_err);

            if !Tolerance::within(act, exp, abs_tol, rel_tol) {
                let name = signal_names.get(s).cloned().unwrap_or_else(|| format!("signal_{s}"));
                failing.push(SignalMismatch {
                    signal_name: name,
                    index: t,
                    expected: exp,
                    actual: act,
                    abs_error: abs_err,
                    rel_error: rel_err,
                });
            }
        }
    }

    CompareResult {
        passed: failing.is_empty(),
        max_abs_error: max_abs,
        max_rel_error: max_rel,
        total_points: total,
        failing_points: failing,
    }
}
