//! Monte Carlo driver — Phase 3.6.
//!
//! Repeatedly perturbs the circuit's element parameters according to a list
//! of [`StatExpr`] overrides, runs the requested analysis on each sample, and
//! aggregates the results into a [`McSampleResults`] SoA container.
//!
//! # HSPICE LOT / DEV semantics
//!
//! Each [`StatOverride`] carries a [`Matching`] qualifier:
//!
//! - `Matching::Dev` (default) — every override gets an **independent** random
//!   draw per sample.  The PRNG stream is seeded by `(sample_idx, override_id)`
//!   so two `DEV` overrides on different instances draw uncorrelated values.
//! - `Matching::Lot` — overrides that share a `lot_tag` see the **same** draw
//!   per sample.  Used to model wafer-level process variation: every BJT that
//!   references the same `.MODEL Q1` line will share its `Vbe` mismatch.
//!
//! Sample 0 always uses the nominal (un-perturbed) value of each `StatExpr`
//! so users can compare against the deterministic operating point.
//!
//! # Determinism
//!
//! Given a fixed `seed`, the same `(McConfig, overrides)` pair always produces
//! identical sample sequences regardless of analysis kind or parallel
//! execution — each sample's seeded `StatRng` is derived purely from
//! `(seed, sample_idx)` via [`StatRng::derive_stream`].
//!
//! # SoA layout
//!
//! Per CLAUDE.md DOD guidelines, [`McSampleResults`] stores measurement values
//! in a flat `Vec<f64>` indexed `sample * num_measures + measure`.  The
//! per-measure helpers (`measure_values`, `mean_of`, `stddev_of`) return
//! contiguous slices that can feed downstream statistics or `.mt0` writers
//! without re-shaping.

use pisim_core::{Circuit, Matching, SimError, StatExpr, StatRng};
use rayon::prelude::*;

// ---------------------------------------------------------------------------
// Public configuration types
// ---------------------------------------------------------------------------

/// One element-parameter override that should be re-sampled every Monte Carlo
/// iteration.
///
/// `device_name` and `param_key` identify the target via
/// [`Circuit::set_device_param`].  `expr` provides the statistical
/// distribution.  `lot_tag` is the model name (or any other shared key) when
/// `expr.matching == Matching::Lot`; ignored otherwise.
#[derive(Debug, Clone)]
pub struct StatOverride {
    /// Element name to mutate, e.g. `"r1"`.
    pub device_name: String,
    /// Parameter key on that element, e.g. `"resistance"`.
    pub param_key: String,
    /// Statistical expression that produces the per-sample value.
    pub expr: StatExpr,
    /// Group key for `LOT` matching (typically the parent `.MODEL` name).
    /// Ignored unless `expr.matching == Matching::Lot`.
    pub lot_tag: Option<String>,
}

impl StatOverride {
    pub fn new(device_name: impl Into<String>, param_key: impl Into<String>, expr: StatExpr) -> Self {
        Self {
            device_name: device_name.into(),
            param_key: param_key.into(),
            expr,
            lot_tag: None,
        }
    }

    pub fn with_lot_tag(mut self, tag: impl Into<String>) -> Self {
        self.lot_tag = Some(tag.into());
        self
    }
}

/// Configuration for a Monte Carlo run.
#[derive(Debug, Clone)]
pub struct McConfig {
    /// Number of samples to draw, including the nominal sample at index 0.
    pub nsamples: usize,
    /// Master PRNG seed.  Identical seeds produce identical sample sequences.
    pub seed: u64,
    /// Whether to evaluate samples in parallel via rayon (when available).
    ///
    /// Falls back to a serial loop when `rayon` is not a workspace dependency
    /// — Phase 3.6 keeps the dependency list minimal so the default is `false`.
    pub parallel: bool,
}

impl Default for McConfig {
    fn default() -> Self {
        Self {
            nsamples: 100,
            seed: 0xC0FFEE_u64,
            parallel: false,
        }
    }
}

// ---------------------------------------------------------------------------
// Per-sample SoA result store
// ---------------------------------------------------------------------------

/// Aggregated measurement results across all Monte Carlo samples.
///
/// Stored in SoA-flat form (`sample * num_measures + measure`) so the
/// per-measure column can be returned as a contiguous `&[f64]` for downstream
/// statistics, the `.mt0` writer, or SIMD reductions.
#[derive(Debug, Clone)]
pub struct McSampleResults {
    /// Measurement names in the order their values appear in each row.
    pub measure_names: Vec<String>,
    /// Number of samples (= number of rows).
    pub nsamples: usize,
    /// Flat row-major buffer: `values[sample * measure_names.len() + measure]`.
    pub values: Vec<f64>,
    /// Per-sample status: `Ok(())` on success, `Err(message)` on failure.
    /// Failed samples have `f64::NAN` in their value row.
    pub status: Vec<Result<(), String>>,
}

impl McSampleResults {
    /// Create an empty results container with the given column ordering.
    pub fn new(measure_names: Vec<String>, nsamples: usize) -> Self {
        let m = measure_names.len();
        Self {
            measure_names,
            nsamples,
            values: vec![f64::NAN; nsamples * m],
            status: vec![Ok(()); nsamples],
        }
    }

    /// Number of measurement columns.
    pub fn num_measures(&self) -> usize {
        self.measure_names.len()
    }

    /// Store one row of measurement values.  Length must equal `num_measures()`.
    pub fn set_row(&mut self, sample_idx: usize, row: &[f64]) {
        debug_assert_eq!(row.len(), self.num_measures());
        let m = self.num_measures();
        let off = sample_idx * m;
        self.values[off..off + m].copy_from_slice(row);
    }

    /// Mark a sample as failed and fill its row with NaN.
    pub fn mark_failed(&mut self, sample_idx: usize, msg: impl Into<String>) {
        let m = self.num_measures();
        let off = sample_idx * m;
        for v in self.values[off..off + m].iter_mut() {
            *v = f64::NAN;
        }
        self.status[sample_idx] = Err(msg.into());
    }

    /// Borrow one column as a freshly-allocated `Vec<f64>` (skipping NaNs is
    /// the caller's responsibility).  Returns `None` if the name is unknown.
    pub fn measure_values(&self, name: &str) -> Option<Vec<f64>> {
        let col = self
            .measure_names
            .iter()
            .position(|n| n.eq_ignore_ascii_case(name))?;
        let m = self.num_measures();
        Some(
            (0..self.nsamples)
                .map(|s| self.values[s * m + col])
                .collect(),
        )
    }

    /// Mean of the named measure, ignoring NaN samples.
    pub fn mean_of(&self, name: &str) -> Option<f64> {
        let vals = self.measure_values(name)?;
        let finite: Vec<f64> = vals.into_iter().filter(|v| v.is_finite()).collect();
        if finite.is_empty() {
            return None;
        }
        Some(finite.iter().sum::<f64>() / finite.len() as f64)
    }

    /// Sample standard deviation of the named measure (Bessel-corrected),
    /// ignoring NaN samples.  Returns `None` for fewer than 2 finite samples.
    pub fn stddev_of(&self, name: &str) -> Option<f64> {
        let vals = self.measure_values(name)?;
        let finite: Vec<f64> = vals.into_iter().filter(|v| v.is_finite()).collect();
        if finite.len() < 2 {
            return None;
        }
        let n = finite.len() as f64;
        let mean = finite.iter().sum::<f64>() / n;
        let var = finite.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / (n - 1.0);
        Some(var.sqrt())
    }

    /// Min of the named measure, ignoring NaN samples.
    pub fn min_of(&self, name: &str) -> Option<f64> {
        let vals = self.measure_values(name)?;
        vals.into_iter()
            .filter(|v| v.is_finite())
            .fold(None, |acc, v| match acc {
                None => Some(v),
                Some(m) => Some(m.min(v)),
            })
    }

    /// Max of the named measure, ignoring NaN samples.
    pub fn max_of(&self, name: &str) -> Option<f64> {
        let vals = self.measure_values(name)?;
        vals.into_iter()
            .filter(|v| v.is_finite())
            .fold(None, |acc, v| match acc {
                None => Some(v),
                Some(m) => Some(m.max(v)),
            })
    }

    /// Number of samples that completed successfully.
    pub fn num_successes(&self) -> usize {
        self.status.iter().filter(|s| s.is_ok()).count()
    }
}

// ---------------------------------------------------------------------------
// Per-sample value computation
// ---------------------------------------------------------------------------

/// Compute the realised value of every override for a given sample index.
///
/// `Dev` overrides each get their own derived stream tagged by their position
/// in the override list, while `Lot` overrides sharing the same `lot_tag` are
/// pooled into a single shared draw.  This matches HSPICE semantics where a
/// `LOT` parameter on a `.MODEL` is drawn once per sample regardless of how
/// many instances reference it.
///
/// Returns a `Vec<f64>` of the same length as `overrides`, in declaration order.
pub fn realise_sample(
    overrides: &[StatOverride],
    sample_idx: usize,
    master: &StatRng,
) -> Vec<f64> {
    // Sample 0 is always nominal — never perturbed — so users can compare
    // against the deterministic operating point.
    if sample_idx == 0 {
        return overrides.iter().map(|o| o.expr.nominal()).collect();
    }

    // Per-sample sub-stream — independent across samples.
    let sample_stream = master.derive_stream(0xA1B2_C3D4u64 ^ sample_idx as u64);

    // Pre-draw one (z, u, bit) triple per LOT tag so all overrides sharing the
    // tag agree.  We iterate the overrides in order so the tag insertion is
    // deterministic.
    let mut lot_draws: ahash::AHashMap<String, (f64, f64, bool)> = ahash::AHashMap::new();
    for ov in overrides
        .iter()
        .filter(|o| o.expr.matching == Matching::Lot)
    {
        let tag = ov
            .lot_tag
            .clone()
            .unwrap_or_else(|| ov.device_name.clone());
        if lot_draws.contains_key(&tag) {
            continue;
        }
        // Deterministic per-tag stream derived from the sample stream so two
        // different LOT groups within the same sample stay independent.
        let mut s = sample_stream.derive_stream(stable_str_hash(&tag));
        let z = s.next_normal();
        let u = s.next_uniform_signed();
        let bit = (s.next_u64() & 1) == 1;
        lot_draws.insert(tag, (z, u, bit));
    }

    // Build the realised value for each override in declaration order.
    overrides
        .iter()
        .enumerate()
        .map(|(idx, ov)| match ov.expr.matching {
            Matching::Lot => {
                let tag = ov
                    .lot_tag
                    .clone()
                    .unwrap_or_else(|| ov.device_name.clone());
                let (z, u, bit) = lot_draws
                    .get(&tag)
                    .copied()
                    .unwrap_or((0.0, 0.0, false));
                ov.expr.sample(z, u, bit)
            }
            Matching::Dev => {
                // Tag the dev stream with the override's declaration index so
                // two distinct DEV overrides draw uncorrelated values.
                let mut s = sample_stream.derive_stream(dev_index_tag(idx));
                let z = s.next_normal();
                let u = s.next_uniform_signed();
                let bit = (s.next_u64() & 1) == 1;
                ov.expr.sample(z, u, bit)
            }
        })
        .collect()
}

/// Scramble a string into a 64-bit tag suitable for [`StatRng::derive_stream`].
///
/// FNV-1a 64-bit — tiny, deterministic, no `Hasher` allocation.
fn stable_str_hash(s: &str) -> u64 {
    let mut h: u64 = 0xCBF2_9CE4_8422_2325;
    for b in s.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01B3);
    }
    h
}

/// Mix a `Dev` override's declaration index into a 64-bit derive-stream tag.
#[inline]
fn dev_index_tag(idx: usize) -> u64 {
    (idx as u64).wrapping_add(0x9E37_79B9_7F4A_7C15)
}

// ---------------------------------------------------------------------------
// Per-sample driver — generic over the user's analysis closure
// ---------------------------------------------------------------------------

/// Run a Monte Carlo experiment.
///
/// `eval_sample` is invoked once per sample with a *clone* of the original
/// circuit, the per-sample realised override values, and the sample index.
/// It must return one row of measurement values whose length matches
/// `measure_names.len()`.
///
/// The driver applies the realised values to the cloned circuit via
/// [`Circuit::set_device_param`] before invoking the closure.  Sample 0 uses
/// the nominal values (un-perturbed); samples 1..nsamples are stochastic.
///
/// # Errors
///
/// Per-sample errors do not abort the run.  Failed samples are recorded as
/// `Err(message)` in [`McSampleResults::status`] and their value row is
/// filled with NaN, so downstream statistics treat them as missing data.
pub fn run_mc<F>(
    base_circuit: &Circuit,
    overrides: &[StatOverride],
    measure_names: Vec<String>,
    config: &McConfig,
    eval_sample: F,
) -> Result<McSampleResults, SimError>
where
    F: Fn(&Circuit, usize) -> Result<Vec<f64>, SimError> + Send + Sync,
{
    let master = StatRng::new(config.seed);
    let num_measures = measure_names.len();

    // Build per-sample (circuit, realised_values) pairs up-front so that both
    // the serial and parallel paths share the same preparation logic.
    let samples: Vec<(usize, Circuit)> = (0..config.nsamples)
        .map(|sample_idx| {
            let realised = realise_sample(overrides, sample_idx, &master);
            let mut sample_circuit = base_circuit.clone();
            for (ov, &val) in overrides.iter().zip(realised.iter()) {
                sample_circuit.set_device_param(&ov.device_name, &ov.param_key, val);
            }
            (sample_idx, sample_circuit)
        })
        .collect();

    // Evaluate samples — parallel when `config.parallel = true`, serial otherwise.
    // Each sample is seeded deterministically from `(master_seed, sample_idx)` so
    // the result is identical regardless of thread ordering.
    let raw: Vec<(usize, Result<Vec<f64>, SimError>)> = if config.parallel {
        samples
            .into_par_iter()
            .map(|(idx, ckt)| (idx, eval_sample(&ckt, idx)))
            .collect()
    } else {
        samples
            .into_iter()
            .map(|(idx, ckt)| (idx, eval_sample(&ckt, idx)))
            .collect()
    };

    let mut results = McSampleResults::new(measure_names, config.nsamples);
    for (sample_idx, outcome) in raw {
        match outcome {
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
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use pisim_core::{DeviceId, DeviceInstance, DeviceKind, NodeId, StatKind};
    use pisim_device::DeviceRegistry;

    fn divider(r1_value: f64) -> Circuit {
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
            .with_param("resistance", r1_value),
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
    fn nominal_sample_uses_mean_value() {
        let stat = StatExpr {
            kind: StatKind::AGauss,
            mean: 1000.0,
            variation: 50.0,
            nsig: 1.0,
            matching: Matching::Dev,
        };
        let overrides = vec![StatOverride::new("r1", "resistance", stat)];
        let master = StatRng::new(42);
        let row = realise_sample(&overrides, 0, &master);
        assert_eq!(row.len(), 1);
        assert!((row[0] - 1000.0).abs() < 1e-12);
    }

    #[test]
    fn lot_overrides_share_a_draw() {
        let stat = StatExpr {
            kind: StatKind::AGauss,
            mean: 100.0,
            variation: 10.0,
            nsig: 1.0,
            matching: Matching::Lot,
        };
        let overrides = vec![
            StatOverride::new("r1", "resistance", stat.clone()).with_lot_tag("MODA"),
            StatOverride::new("r2", "resistance", stat.clone()).with_lot_tag("MODA"),
            StatOverride::new("r3", "resistance", stat).with_lot_tag("MODB"),
        ];
        let master = StatRng::new(0xDEAD_BEEF);
        let row = realise_sample(&overrides, 7, &master);
        assert_eq!(row.len(), 3);
        // r1 and r2 share a tag — same draw.
        assert!((row[0] - row[1]).abs() < 1e-12);
        // r3 has a different tag — different draw (overwhelmingly likely).
        assert!((row[0] - row[2]).abs() > 1e-9);
    }

    #[test]
    fn dev_overrides_independent() {
        let stat = StatExpr {
            kind: StatKind::AGauss,
            mean: 100.0,
            variation: 10.0,
            nsig: 1.0,
            matching: Matching::Dev,
        };
        let overrides = vec![
            StatOverride::new("r1", "resistance", stat.clone()),
            StatOverride::new("r2", "resistance", stat),
        ];
        let master = StatRng::new(0xDEAD_BEEF);
        let row = realise_sample(&overrides, 3, &master);
        // Independent draws — overwhelmingly unlikely to coincide.
        assert!((row[0] - row[1]).abs() > 1e-9);
    }

    #[test]
    fn determinism_across_runs() {
        let stat = StatExpr {
            kind: StatKind::Gauss,
            mean: 1000.0,
            variation: 0.05,
            nsig: 1.0,
            matching: Matching::Dev,
        };
        let overrides = vec![StatOverride::new("r1", "resistance", stat)];
        let master = StatRng::new(0xC0FFEE);
        let a: Vec<f64> = (0..50)
            .flat_map(|i| realise_sample(&overrides, i, &master))
            .collect();
        let b: Vec<f64> = (0..50)
            .flat_map(|i| realise_sample(&overrides, i, &master))
            .collect();
        assert_eq!(a, b);
    }

    #[test]
    fn agauss_sample_mean_and_stddev() {
        // Drive run_mc against a divider with R1 = AGAUSS(1k, 50, 1nsig).
        // Expect: empirical mean ≈ 1000, stddev ≈ 50.  Use 1k samples and a
        // 5% tolerance band on each statistic — wide enough to be stable.
        let base = divider(1000.0);
        let reg = DeviceRegistry::new_default();
        let stat = StatExpr {
            kind: StatKind::AGauss,
            mean: 1000.0,
            variation: 50.0,
            nsig: 1.0,
            matching: Matching::Dev,
        };
        let overrides = vec![StatOverride::new("R1", "resistance", stat)];

        let cfg = McConfig {
            nsamples: 1000,
            seed: 0xBEEF,
            parallel: false,
        };

        let results = run_mc(
            &base,
            &overrides,
            vec!["r1_value".into(), "v_out".into()],
            &cfg,
            |ckt, _idx| {
                let out = crate::dc_op::run_dc_op(ckt, &reg)
                    .map_err(|e| SimError::Analysis(format!("dc_op: {e}")))?;
                let r1 = ckt.find_device("R1").unwrap().params.get("resistance").unwrap();
                let v2 = out
                    .result
                    .node_voltages
                    .iter()
                    .find(|(n, _)| n == "2")
                    .map(|(_, v)| *v)
                    .unwrap_or(f64::NAN);
                Ok(vec![r1, v2])
            },
        )
        .unwrap();

        assert_eq!(results.nsamples, 1000);
        assert_eq!(results.num_successes(), 1000);

        // Sample 0 must be exactly nominal (1k, divider gives 2.5).
        let row0_r1 = results.values[0];
        let row0_v2 = results.values[1];
        assert!((row0_r1 - 1000.0).abs() < 1e-9);
        assert!((row0_v2 - 2.5).abs() < 1e-9);

        // Statistics on R1 column.
        let mean_r1 = results.mean_of("r1_value").unwrap();
        let stdev_r1 = results.stddev_of("r1_value").unwrap();
        assert!(
            (mean_r1 - 1000.0).abs() < 10.0,
            "MC mean(R1) = {mean_r1} expected ~1000"
        );
        assert!(
            (stdev_r1 - 50.0).abs() < 6.0,
            "MC stddev(R1) = {stdev_r1} expected ~50"
        );

        // V(out) for the divider is R2/(R1+R2) * 5 = 5000/(R1+1000).
        // Mean should be close to the nominal 2.5.
        let mean_vout = results.mean_of("v_out").unwrap();
        assert!(
            (mean_vout - 2.5).abs() < 0.05,
            "MC mean(V(2)) = {mean_vout} expected ~2.5"
        );
    }

    #[test]
    fn measure_lookups() {
        let mut r = McSampleResults::new(vec!["a".into(), "b".into()], 4);
        r.set_row(0, &[1.0, 10.0]);
        r.set_row(1, &[2.0, 20.0]);
        r.set_row(2, &[3.0, 30.0]);
        r.set_row(3, &[4.0, 40.0]);
        assert_eq!(r.mean_of("a"), Some(2.5));
        assert_eq!(r.mean_of("b"), Some(25.0));
        assert!((r.stddev_of("a").unwrap() - 1.2909944).abs() < 1e-6);
        assert_eq!(r.min_of("b"), Some(10.0));
        assert_eq!(r.max_of("b"), Some(40.0));
    }

    #[test]
    fn failed_sample_rows_are_nan() {
        let mut r = McSampleResults::new(vec!["x".into()], 3);
        r.set_row(0, &[1.0]);
        r.mark_failed(1, "boom");
        r.set_row(2, &[3.0]);
        assert_eq!(r.num_successes(), 2);
        let col = r.measure_values("x").unwrap();
        assert!(col[0].is_finite());
        assert!(col[1].is_nan());
        assert!(col[2].is_finite());
        assert!((r.mean_of("x").unwrap() - 2.0).abs() < 1e-9);
    }
}
