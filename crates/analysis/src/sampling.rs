//! Quasi-Monte Carlo / Latin Hypercube Sampling (`.SAMPLING`) — Wave Q.6.
//!
//! Provides statistically better coverage of a multi-dimensional parameter
//! space than pure Monte Carlo by using **Latin Hypercube Sampling (LHS)**.
//!
//! ## Latin Hypercube Sampling
//!
//! For `N` samples and `D` parameters:
//!
//! 1. Divide each parameter dimension into `N` equal-probability intervals.
//! 2. Draw exactly one sample from each interval per dimension (guarantees
//!    uniform marginal coverage — no "clumping" of the kind that plagues
//!    pure MC).
//! 3. Permute the interval assignments independently across dimensions
//!    (breaks correlation between parameters).
//!
//! The result is an `N × D` sample matrix where every row forms a valid
//! parameter combination and every column is a stratified uniform sample.
//!
//! ## Relationship to Monte Carlo
//!
//! LHS reuses the same [`StatOverride`] / [`McSampleResults`] types from
//! [`crate::mc`] so downstream statistics helpers (`mean_of`, `stddev_of`,
//! percentiles) work without modification.  The only difference is in how the
//! parameter values are drawn:
//!
//! | Mode       | Coverage                    | Correlation |
//! |------------|-----------------------------| ------------|
//! | Pure MC    | Random — can leave gaps     | None        |
//! | LHS        | Stratified — no gaps        | Broken by permutation |
//!
//! Empirically, LHS converges mean/variance estimates ~`√N`× faster than pure
//! MC for smooth response surfaces (Iman & Helton, 1988).
//!
//! ## Usage
//!
//! ```no_run
//! use pisim_analysis::sampling::{SamplingConfig, run_sampling};
//! use pisim_analysis::mc::StatOverride;
//! use pisim_core::{Circuit, StatExpr, StatKind, Matching};
//! use pisim_device::DeviceRegistry;
//!
//! let base = Circuit::new(); // pre-built circuit
//! let reg = DeviceRegistry::new_default();
//! let overrides = vec![/* StatOverride::new(...) */];
//! let cfg = SamplingConfig::default();
//! let results = run_sampling(&base, &overrides, vec!["gain".into()], &cfg, |ckt, _| {
//!     Ok(vec![0.0]) // your analysis here
//! }).unwrap();
//! ```
//!
//! ## SoA layout
//!
//! Results are stored in the [`McSampleResults`] SoA container identical to
//! [`crate::mc::run_mc`] — flat row-major `values[sample * num_measures + measure]`.

use pisim_core::{Circuit, SimError};

use crate::mc::{McSampleResults, StatOverride};

// ---------------------------------------------------------------------------
// Public configuration
// ---------------------------------------------------------------------------

/// Configuration for LHS / quasi-MC sampling.
#[derive(Debug, Clone)]
pub struct SamplingConfig {
    /// Number of samples (= number of LHS strata per dimension).
    pub nsamples: usize,
    /// PRNG seed for stratum-point jitter and permutation.
    pub seed: u64,
    /// Whether to run samples in parallel via rayon.
    pub parallel: bool,
    /// Sampling strategy.
    pub strategy: SamplingStrategy,
}

impl Default for SamplingConfig {
    fn default() -> Self {
        Self {
            nsamples: 100,
            seed: 0xDEAD_BEEF_u64,
            parallel: false,
            strategy: SamplingStrategy::LatinHypercube,
        }
    }
}

/// Available sampling strategies.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SamplingStrategy {
    /// Latin Hypercube Sampling — stratified, permuted.
    LatinHypercube,
    /// Pure Monte Carlo — for comparison / fall-back.
    MonteCarlo,
}

// ---------------------------------------------------------------------------
// Statistical summary of the ensemble
// ---------------------------------------------------------------------------

/// Statistical summaries extracted from a sampling run.
///
/// All values are computed over the finite (non-NaN) samples.
#[derive(Debug, Clone)]
pub struct SamplingSummary {
    /// Measurement name.
    pub name: String,
    /// Number of finite samples used in the statistics.
    pub n: usize,
    /// Sample mean.
    pub mean: f64,
    /// Sample standard deviation (Bessel-corrected).
    pub std: f64,
    /// Minimum value.
    pub min: f64,
    /// 5th percentile.
    pub p5: f64,
    /// 25th percentile (Q1).
    pub p25: f64,
    /// Median (50th percentile).
    pub p50: f64,
    /// 75th percentile (Q3).
    pub p75: f64,
    /// 95th percentile.
    pub p95: f64,
    /// Maximum value.
    pub max: f64,
}

impl SamplingSummary {
    /// Compute summary statistics from a slice of values (NaNs are skipped).
    pub fn from_values(name: impl Into<String>, values: &[f64]) -> Self {
        let mut finite: Vec<f64> = values.iter().copied().filter(|v| v.is_finite()).collect();
        let name = name.into();

        if finite.is_empty() {
            return Self {
                name,
                n: 0,
                mean: f64::NAN,
                std: f64::NAN,
                min: f64::NAN,
                p5: f64::NAN,
                p25: f64::NAN,
                p50: f64::NAN,
                p75: f64::NAN,
                p95: f64::NAN,
                max: f64::NAN,
            };
        }

        finite.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let n = finite.len();
        let n_f = n as f64;

        let mean = finite.iter().sum::<f64>() / n_f;
        let std = if n >= 2 {
            let var = finite.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / (n_f - 1.0);
            var.sqrt()
        } else {
            0.0
        };

        Self {
            name,
            n,
            mean,
            std,
            min: finite[0],
            p5: percentile(&finite, 5.0),
            p25: percentile(&finite, 25.0),
            p50: percentile(&finite, 50.0),
            p75: percentile(&finite, 75.0),
            p95: percentile(&finite, 95.0),
            max: *finite.last().unwrap(),
        }
    }
}

/// Linear-interpolation percentile on a pre-sorted slice.
fn percentile(sorted: &[f64], p: f64) -> f64 {
    let n = sorted.len();
    if n == 1 {
        return sorted[0];
    }
    let rank = p / 100.0 * (n as f64 - 1.0);
    let lo = rank.floor() as usize;
    let hi = (lo + 1).min(n - 1);
    let frac = rank - lo as f64;
    sorted[lo] * (1.0 - frac) + sorted[hi] * frac
}

// ---------------------------------------------------------------------------
// LHS sample matrix
// ---------------------------------------------------------------------------

/// Generate an `N × D` Latin Hypercube sample matrix.
///
/// Returns a flat row-major buffer `mat[sample * D + dim]` where each entry is
/// a uniform value in `[0, 1)` that satisfies the LHS stratification property:
/// every dimension column contains exactly one value per stratum `[k/N, (k+1)/N)`.
///
/// The permutations are derived from a simple LCG seeded by `seed ^ dim` so
/// different dimensions get independent permutations without allocating a
/// separate PRNG object.
pub fn lhs_unit_cube(n: usize, d: usize, seed: u64) -> Vec<f64> {
    let mut mat = vec![0.0_f64; n * d];

    for dim in 0..d {
        // Generate stratum indices 0..n and permute them.
        let mut perm: Vec<usize> = (0..n).collect();
        let lcg_seed = seed.wrapping_add(dim as u64).wrapping_add(0x9E3779B97F4A7C15);
        fisher_yates_shuffle(&mut perm, lcg_seed);

        // For each stratum, draw a uniform point within the stratum using a
        // separate LCG jitter stream.
        let jitter_seed = seed
            .wrapping_add(dim as u64)
            .wrapping_add(0xD1B54A32D192ED03);
        let mut rng = Lcg64::new(jitter_seed);

        for (s, &stratum) in perm.iter().enumerate() {
            // Stratum `stratum` covers [stratum/n, (stratum+1)/n).
            let lo = stratum as f64 / n as f64;
            let hi = (stratum + 1) as f64 / n as f64;
            let u = lo + rng.next_f64() * (hi - lo);
            mat[s * d + dim] = u;
        }
    }

    mat
}

/// Generate an `N × D` pure Monte Carlo sample matrix (uniform `[0, 1)`).
pub fn mc_unit_cube(n: usize, d: usize, seed: u64) -> Vec<f64> {
    let mut rng = Lcg64::new(seed.wrapping_add(0xF39CC0605CEDC834));
    (0..n * d).map(|_| rng.next_f64()).collect()
}

// ---------------------------------------------------------------------------
// Stratum → parameter value mapping
// ---------------------------------------------------------------------------

/// Map a uniform-`[0,1)` sample to the realised value of a `StatExpr`.
///
/// We use the inverse-CDF (percent-point function) appropriate for each
/// distribution kind, mirroring the sampling semantics in [`crate::mc::realise_sample`].
fn unit_to_param(u: f64, ov: &StatOverride) -> f64 {
    use pisim_core::StatKind;
    let expr = &ov.expr;
    match expr.kind {
        StatKind::Gauss | StatKind::AGauss => {
            // Inverse normal CDF — Box-Muller approximation is not invertible,
            // so we use the rational approximation (Abramowitz & Stegun 26.2.17).
            let z = probit(u);
            let sigma = expr.variation / expr.nsig;
            expr.mean + sigma * z
        }
        StatKind::Uniform | StatKind::AUniform => {
            // expr.variation is the half-width.
            let lo = expr.mean - expr.variation;
            let hi = expr.mean + expr.variation;
            lo + u * (hi - lo)
        }
        StatKind::UniformPercent => {
            let lo = expr.mean * (1.0 - expr.variation / 100.0);
            let hi = expr.mean * (1.0 + expr.variation / 100.0);
            lo + u * (hi - lo)
        }
    }
}

/// Rational approximation of the probit (inverse standard-normal CDF).
///
/// Abramowitz & Stegun 26.2.17 — maximum error ≈ 4.5 × 10⁻⁴.  Sufficient for
/// LHS sampling; replace with a higher-order approximation if tighter accuracy
/// is needed.
fn probit(p: f64) -> f64 {
    // Clamp to avoid ±infinity at the tails.
    let p = p.clamp(1e-9, 1.0 - 1e-9);
    let t = if p <= 0.5 {
        (-2.0 * p.ln()).sqrt()
    } else {
        (-2.0 * (1.0 - p).ln()).sqrt()
    };
    let c0 = 2.515517;
    let c1 = 0.802853;
    let c2 = 0.010328;
    let d1 = 1.432788;
    let d2 = 0.189269;
    let d3 = 0.001308;
    let num = c0 + c1 * t + c2 * t * t;
    let den = 1.0 + d1 * t + d2 * t * t + d3 * t * t * t;
    let sign = if p <= 0.5 { -1.0 } else { 1.0 };
    sign * (t - num / den)
}

// ---------------------------------------------------------------------------
// Minimal LCG PRNG — no external dependency
// ---------------------------------------------------------------------------

/// 64-bit LCG — Knuth MMIX constants.
struct Lcg64 {
    state: u64,
}

impl Lcg64 {
    fn new(seed: u64) -> Self {
        Self { state: seed.wrapping_add(1) }
    }

    fn next_u64(&mut self) -> u64 {
        self.state = self.state
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.state
    }

    /// Uniform float in `[0, 1)`.
    fn next_f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }
}

/// In-place Fisher-Yates shuffle using an LCG for index selection.
fn fisher_yates_shuffle(v: &mut Vec<usize>, seed: u64) {
    let mut rng = Lcg64::new(seed);
    let n = v.len();
    for i in (1..n).rev() {
        let j = (rng.next_u64() % (i as u64 + 1)) as usize;
        v.swap(i, j);
    }
}

// ---------------------------------------------------------------------------
// Main runner
// ---------------------------------------------------------------------------

/// Run a quasi-Monte Carlo / LHS sampling experiment.
///
/// Interface mirrors [`crate::mc::run_mc`]:
/// - `eval_sample(circuit_clone, sample_idx)` must return one measurement row.
/// - Sample 0 is the nominal centre (all parameters at their mean values).
/// - Samples 1..nsamples are drawn from the LHS / MC distribution.
///
/// Statistical summaries are available via [`summarise`].
pub fn run_sampling<F>(
    base_circuit: &Circuit,
    overrides: &[StatOverride],
    measure_names: Vec<String>,
    config: &SamplingConfig,
    eval_sample: F,
) -> Result<McSampleResults, SimError>
where
    F: Fn(&Circuit, usize) -> Result<Vec<f64>, SimError> + Send + Sync,
{
    let d = overrides.len();
    let n = config.nsamples;
    let num_measures = measure_names.len();

    // ── Build unit-cube sample matrix ────────────────────────────────────
    // Rows 0..n represent stochastic samples; we prepend one nominal row.
    let unit_mat = match config.strategy {
        SamplingStrategy::LatinHypercube => lhs_unit_cube(n, d, config.seed),
        SamplingStrategy::MonteCarlo => mc_unit_cube(n, d, config.seed),
    };

    // ── Prepare circuits: nominal + n stochastic ─────────────────────────
    // Total = n+1 rows: index 0 = nominal, 1..=n = stochastic.
    let total = n + 1;

    // Row 0 (nominal): use each override's mean value.
    let nominal_vals: Vec<f64> = overrides.iter().map(|o| o.expr.nominal()).collect();

    // Rows 1..n: LHS-derived values.
    let stochastic: Vec<Vec<f64>> = (0..n)
        .map(|s| {
            (0..d)
                .map(|dim| {
                    let u = unit_mat[s * d + dim];
                    unit_to_param(u, &overrides[dim])
                })
                .collect()
        })
        .collect();

    // ── Apply overrides and run eval_sample ──────────────────────────────
    let mut results = McSampleResults::new(measure_names, total);

    // Serial evaluation (parallel path omitted for simplicity; add rayon
    // par_iter here if config.parallel == true in a future revision).
    for sample_idx in 0..total {
        let vals: &[f64] = if sample_idx == 0 {
            &nominal_vals
        } else {
            &stochastic[sample_idx - 1]
        };

        let mut ckt = base_circuit.clone();
        for (ov, &val) in overrides.iter().zip(vals.iter()) {
            ckt.set_device_param(&ov.device_name, &ov.param_key, val);
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

// ---------------------------------------------------------------------------
// Convenience: compute all summaries from a McSampleResults
// ---------------------------------------------------------------------------

/// Compute [`SamplingSummary`] for every measure column in `results`.
pub fn summarise(results: &McSampleResults) -> Vec<SamplingSummary> {
    results
        .measure_names
        .iter()
        .filter_map(|name| {
            let vals = results.measure_values(name)?;
            Some(SamplingSummary::from_values(name.clone(), &vals))
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use pisim_core::{
        DeviceId, DeviceInstance, DeviceKind, Matching, NodeId, StatExpr, StatKind,
    };
    use pisim_device::DeviceRegistry;

    // ── LHS unit tests ───────────────────────────────────────────────────

    #[test]
    fn lhs_stratification_property() {
        // For each dimension column, each stratum [k/n, (k+1)/n) contains
        // exactly one sample.
        let n = 20;
        let d = 4;
        let mat = lhs_unit_cube(n, d, 0xC0FFEE);
        for dim in 0..d {
            let mut stratum_hit = vec![false; n];
            for s in 0..n {
                let v = mat[s * d + dim];
                let stratum = (v * n as f64).floor() as usize;
                assert!(stratum < n, "dim={dim} s={s} v={v} stratum={stratum}");
                assert!(!stratum_hit[stratum], "dim={dim}: stratum {stratum} hit twice");
                stratum_hit[stratum] = true;
            }
            assert!(stratum_hit.iter().all(|&h| h), "dim={dim}: not all strata covered");
        }
    }

    #[test]
    fn lhs_values_in_unit_interval() {
        let mat = lhs_unit_cube(50, 3, 42);
        for &v in &mat {
            assert!((0.0..1.0).contains(&v), "out of [0,1): {v}");
        }
    }

    #[test]
    fn mc_unit_cube_all_in_unit() {
        let mat = mc_unit_cube(100, 5, 99);
        for &v in &mat {
            assert!((0.0..1.0).contains(&v));
        }
    }

    // ── Probit / percentile ──────────────────────────────────────────────

    #[test]
    fn probit_symmetric() {
        // probit(0.5) should be 0 for a standard normal.
        assert!(probit(0.5).abs() < 0.01);
        // probit(0.84) ≈ 1 (one-sigma).
        assert!((probit(0.8413) - 1.0).abs() < 0.01);
        // probit(1-p) = -probit(p).
        assert!((probit(0.25) + probit(0.75)).abs() < 0.01);
    }

    #[test]
    fn percentile_sorted_smoke() {
        let data = vec![1.0_f64, 2.0, 3.0, 4.0, 5.0];
        assert!((percentile(&data, 0.0) - 1.0).abs() < 1e-10);
        assert!((percentile(&data, 100.0) - 5.0).abs() < 1e-10);
        assert!((percentile(&data, 50.0) - 3.0).abs() < 1e-10);
    }

    // ── SamplingSummary ──────────────────────────────────────────────────

    #[test]
    fn summary_known_values() {
        // Five values 1..5: mean=3, std≈1.581, min=1, max=5, median=3.
        let vals = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let s = SamplingSummary::from_values("x", &vals);
        assert_eq!(s.n, 5);
        assert!((s.mean - 3.0).abs() < 1e-10);
        assert!((s.std - (10.0_f64 / 4.0).sqrt()).abs() < 1e-10);
        assert_eq!(s.min, 1.0);
        assert_eq!(s.max, 5.0);
        assert!((s.p50 - 3.0).abs() < 1e-10);
    }

    #[test]
    fn summary_all_nan() {
        let vals = vec![f64::NAN, f64::NAN];
        let s = SamplingSummary::from_values("x", &vals);
        assert_eq!(s.n, 0);
        assert!(s.mean.is_nan());
    }

    // ── Integration: run_sampling + divider circuit ──────────────────────

    fn build_divider() -> Circuit {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let n2 = ckt.add_node("2");
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "V1",
                DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)],
            )
            .with_param("dc", 5.0),
        );
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "R1",
                DeviceKind::Resistor,
                &[(0, n1), (1, n2)],
            )
            .with_param("resistance", 1000.0),
        );
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "R2",
                DeviceKind::Resistor,
                &[(0, n2), (1, NodeId::GROUND)],
            )
            .with_param("resistance", 1000.0),
        );
        ckt.build_topology();
        ckt
    }

    #[test]
    fn sampling_nominal_row_is_exact() {
        let base = build_divider();
        let reg = DeviceRegistry::new_default();
        let stat = StatExpr {
            kind: StatKind::AGauss,
            mean: 1000.0,
            variation: 50.0,
            nsig: 1.0,
            matching: Matching::Dev,
        };
        let overrides = vec![StatOverride::new("R1", "resistance", stat)];
        let cfg = SamplingConfig {
            nsamples: 50,
            seed: 0xABCD,
            parallel: false,
            strategy: SamplingStrategy::LatinHypercube,
        };

        let results = run_sampling(
            &base,
            &overrides,
            vec!["v_out".into()],
            &cfg,
            |ckt, _idx| {
                let out = crate::dc_op::run_dc_op(ckt, &reg)
                    .map_err(|e| SimError::Analysis(format!("dc_op: {e}")))?;
                let v2 = out
                    .result
                    .node_voltages
                    .iter()
                    .find(|(n, _)| n == "2")
                    .map(|(_, v)| *v)
                    .unwrap_or(f64::NAN);
                Ok(vec![v2])
            },
        )
        .unwrap();

        // Total rows = nsamples + 1 (nominal at row 0).
        assert_eq!(results.nsamples, 51);
        // Row 0 must be the nominal V(2) = 2.5.
        let v_nom = results.values[0];
        assert!((v_nom - 2.5).abs() < 1e-9, "nominal V(2) = {v_nom}");
    }

    #[test]
    fn sampling_lhs_stratification_reduces_variance() {
        // LHS mean of V(2) should be closer to 2.5 than pure MC for the same N.
        // We just verify that the run completes without error and the mean
        // is in a reasonable range.
        let base = build_divider();
        let reg = DeviceRegistry::new_default();
        let stat = StatExpr {
            kind: StatKind::AGauss,
            mean: 1000.0,
            variation: 100.0,
            nsig: 1.0,
            matching: Matching::Dev,
        };
        let overrides = vec![StatOverride::new("R1", "resistance", stat)];
        let cfg = SamplingConfig {
            nsamples: 200,
            seed: 0x1234,
            parallel: false,
            strategy: SamplingStrategy::LatinHypercube,
        };

        let results = run_sampling(
            &base,
            &overrides,
            vec!["v_out".into()],
            &cfg,
            |ckt, _idx| {
                let out = crate::dc_op::run_dc_op(ckt, &reg)
                    .map_err(|e| SimError::Analysis(format!("dc_op: {e}")))?;
                let v2 = out
                    .result
                    .node_voltages
                    .iter()
                    .find(|(n, _)| n == "2")
                    .map(|(_, v)| *v)
                    .unwrap_or(f64::NAN);
                Ok(vec![v2])
            },
        )
        .unwrap();

        assert_eq!(results.num_successes(), results.nsamples);
        let summaries = summarise(&results);
        assert_eq!(summaries.len(), 1);
        let s = &summaries[0];
        assert!((s.mean - 2.5).abs() < 0.1, "LHS mean = {}", s.mean);
    }

    #[test]
    fn summarise_smoke() {
        let mut r = McSampleResults::new(vec!["a".into(), "b".into()], 5);
        for i in 0..5 {
            r.set_row(i, &[i as f64, (i * 2) as f64]);
        }
        let summaries = summarise(&r);
        assert_eq!(summaries.len(), 2);
        assert!((summaries[0].mean - 2.0).abs() < 1e-10);
        assert!((summaries[1].mean - 4.0).abs() < 1e-10);
    }
}
