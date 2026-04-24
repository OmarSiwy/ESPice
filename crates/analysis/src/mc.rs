//! Monte Carlo analysis.

use incspice_cache::CacheManager;
use incspice_core::{Circuit, SimError, StatExpr, StreamingSink};
use incspice_solver::device::DeviceRegistry;
use incspice_solver::newton::NrConfig;
use crate::{Analysis, AnalysisError};

pub struct MonteCarlo { pub num_samples: usize }

impl Analysis for MonteCarlo {
    fn run(&self, circuit: &mut Circuit, registry: &DeviceRegistry, _config: &NrConfig, _cache: &mut CacheManager, sink: &mut dyn StreamingSink) -> Result<(), AnalysisError> {
        let solver = incspice_solver::Solver::default();
        let results = run_mc(
            circuit,
            &[],
            vec![],
            self.num_samples,
            0,
            |ckt, _sample_idx| {
                let nr = solver.solve(ckt, registry, None)?;
                Ok(nr.solution.clone())
            },
        ).map_err(|e| AnalysisError::Solver(e))?;

        // Emit one point per sample (x = sample index, y = solution row).
        for sample_idx in 0..results.nsamples {
            if results.failures[sample_idx].is_empty() {
                let nm = results.num_measures();
                let base = sample_idx * nm.max(1);
                let row = if nm > 0 { &results.values[base..base + nm] } else { &[] };
                sink.emit_point(sample_idx as f64, row)?;
            }
        }
        sink.finalize()?;
        Ok(())
    }
    fn name(&self) -> &str { "mc" }
}

// ---------------------------------------------------------------------------
// StatOverride — parameter override descriptor for MC / worst-case
// ---------------------------------------------------------------------------

/// Describes a statistical parameter override: which device, which parameter,
/// and the statistical expression (Gaussian, uniform, etc.) to apply.
#[derive(Debug, Clone)]
pub struct StatOverride {
    /// Device instance name (e.g. `"R1"`).
    pub device_name: String,
    /// Parameter key (e.g. `"resistance"`).
    pub param_key: String,
    /// Statistical expression: distribution kind, mean, variation, etc.
    pub expr: StatExpr,
}

impl StatOverride {
    pub fn new(device_name: impl Into<String>, param_key: impl Into<String>, expr: StatExpr) -> Self {
        Self {
            device_name: device_name.into(),
            param_key: param_key.into(),
            expr,
        }
    }
}

// ---------------------------------------------------------------------------
// McSampleResults — SoA container for Monte Carlo output
// ---------------------------------------------------------------------------

/// Flat SoA container for Monte Carlo results.
///
/// Layout: `values[sample * num_measures + measure_index]`.
/// Failed samples have their row filled with `f64::NAN`.
#[derive(Debug, Clone)]
pub struct McSampleResults {
    /// Measurement names.
    pub measure_names: Vec<String>,
    /// Total number of samples (including nominal at row 0).
    pub nsamples: usize,
    /// Flat row-major values buffer.
    pub values: Vec<f64>,
    /// Per-sample failure reason (empty string = success).
    pub failures: Vec<String>,
}

impl McSampleResults {
    pub fn new(measure_names: Vec<String>, nsamples: usize) -> Self {
        let num_measures = measure_names.len();
        Self {
            measure_names,
            nsamples,
            values: vec![f64::NAN; nsamples * num_measures.max(1)],
            failures: vec![String::new(); nsamples],
        }
    }

    pub fn num_measures(&self) -> usize {
        self.measure_names.len()
    }

    pub fn set_row(&mut self, sample_idx: usize, row: &[f64]) {
        let nm = self.num_measures();
        let base = sample_idx * nm;
        let len = row.len().min(nm);
        self.values[base..base + len].copy_from_slice(&row[..len]);
        self.failures[sample_idx].clear();
    }

    pub fn mark_failed(&mut self, sample_idx: usize, reason: String) {
        let nm = self.num_measures();
        let base = sample_idx * nm;
        for v in &mut self.values[base..base + nm] {
            *v = f64::NAN;
        }
        self.failures[sample_idx] = reason;
    }

    /// Count successfully-evaluated samples (failures is empty string).
    pub fn num_successes(&self) -> usize {
        self.failures.iter().filter(|f| f.is_empty()).count()
    }

    /// Get all values for a named measure. Returns `None` if name not found.
    pub fn measure_values(&self, name: &str) -> Option<Vec<f64>> {
        let idx = self.measure_names.iter().position(|n| n == name)?;
        let nm = self.num_measures();
        let vals: Vec<f64> = (0..self.nsamples).map(|s| self.values[s * nm + idx]).collect();
        Some(vals)
    }
}

// ---------------------------------------------------------------------------
// run_mc — Monte Carlo runner
// ---------------------------------------------------------------------------

/// Run a Monte Carlo experiment.
///
/// `eval_sample` is called once per sample with a circuit clone that has
/// the statistical overrides applied. Sample 0 is the nominal (all means).
pub fn run_mc<F>(
    base_circuit: &Circuit,
    overrides: &[StatOverride],
    measure_names: Vec<String>,
    nsamples: usize,
    seed: u64,
    eval_sample: F,
) -> Result<McSampleResults, SimError>
where
    F: Fn(&Circuit, usize) -> Result<Vec<f64>, SimError>,
{
    let total = nsamples + 1;
    let mut results = McSampleResults::new(measure_names, total);
    let num_measures = results.num_measures();
    let mut rng = incspice_core::StatRng::new(seed);

    for sample_idx in 0..total {
        let mut ckt = base_circuit.clone();
        if sample_idx == 0 {
            // Nominal: use mean values.
            for ov in overrides {
                ckt.set_device_param(&ov.device_name, &ov.param_key, ov.expr.mean);
            }
        } else {
            // Stochastic: sample each override.
            for ov in overrides {
                let z = rng.next_normal();
                let u = rng.next_uniform_signed();
                let bit = rng.next_u64() & 1 != 0;
                let val = ov.expr.sample(z, u, bit);
                ckt.set_device_param(&ov.device_name, &ov.param_key, val);
            }
        }

        match eval_sample(&ckt, sample_idx) {
            Ok(row) if row.len() == num_measures => {
                results.set_row(sample_idx, &row);
            }
            Ok(row) => {
                let mut padded = row;
                padded.resize(num_measures, f64::NAN);
                results.set_row(sample_idx, &padded);
            }
            Err(e) => {
                results.mark_failed(sample_idx, e.to_string());
            }
        }
    }

    Ok(results)
}
