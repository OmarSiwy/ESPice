//! Worst-case corner analysis driver — Phase 3.6.
//!
//! Builds a deterministic enumeration of `±k·sigma` corners across a list of
//! [`StatOverride`]s and runs the requested analysis at each corner.  Two
//! corner-generation strategies are supported:
//!
//! - [`WcaseStrategy::Extreme`] — every override at `+k` and `-k` simultaneously,
//!   plus the nominal centre.  Produces 3 corners regardless of override count
//!   and is the fastest, most pessimistic option.
//! - [`WcaseStrategy::OneAtATime`] — for each override, perturb only that one
//!   to `+k` and to `-k` while leaving the others nominal.  Produces
//!   `2*n + 1` corners and isolates which parameter dominates a given
//!   measurement.
//!
//! Both strategies always include sample 0 = nominal, matching the convention
//! used in [`crate::mc`].
//!
//! Worst-case is much cheaper than Monte Carlo (deterministic, small N) but
//! conservative — it answers "what is the worst possible value within the
//! ±k·sigma envelope?" rather than "what is the realistic distribution?"

use incspice_core::{Circuit, SimError};

use crate::mc::{McSampleResults, StatOverride};

// ---------------------------------------------------------------------------
// Corner-generation strategy
// ---------------------------------------------------------------------------

/// How to enumerate worst-case corners across the override list.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WcaseStrategy {
    /// All overrides at +k together; all at -k together.  Three samples total
    /// (`nominal`, `all_plus`, `all_minus`).
    Extreme,
    /// One override at a time perturbed to ±k.  `2*n + 1` samples.
    OneAtATime,
}

/// Description of a corner that the driver visited — useful for the `.mt0`
/// label column and for users who want to know which row maps to which corner.
#[derive(Debug, Clone)]
pub struct WcaseCorner {
    /// 0 = nominal, 1.. = perturbed corners.
    pub index: usize,
    /// Human-readable label, e.g. `"nominal"`, `"all_plus"`, `"r1_minus"`.
    pub label: String,
    /// The realised override values for this corner.
    pub values: Vec<f64>,
}

/// Configuration for a worst-case run.
#[derive(Debug, Clone)]
pub struct WcaseConfig {
    /// Number of standard deviations / range fractions to drive each
    /// override to at the corners (typical: 1.0 or 3.0).
    pub k: f64,
    /// Corner enumeration strategy.
    pub strategy: WcaseStrategy,
}

impl Default for WcaseConfig {
    fn default() -> Self {
        Self {
            k: 1.0,
            strategy: WcaseStrategy::Extreme,
        }
    }
}

/// Aggregated results of a worst-case run.
///
/// `samples` is the same SoA layout as Monte Carlo so the rest of the
/// pipeline (`.mt0` writer, statistics helpers) can stay shared.  `corners`
/// is a parallel description of which corner produced each row.
#[derive(Debug, Clone)]
pub struct WcaseResults {
    pub samples: McSampleResults,
    pub corners: Vec<WcaseCorner>,
}

// ---------------------------------------------------------------------------
// Corner enumeration
// ---------------------------------------------------------------------------

/// Build the full corner list for a given override set + config.
///
/// The first entry is always the nominal centre.  Subsequent entries depend
/// on the [`WcaseStrategy`].
pub fn enumerate_corners(overrides: &[StatOverride], config: &WcaseConfig) -> Vec<WcaseCorner> {
    let nominal: Vec<f64> = overrides.iter().map(|o| o.expr.nominal()).collect();
    let mut corners = vec![WcaseCorner {
        index: 0,
        label: "nominal".into(),
        values: nominal.clone(),
    }];

    match config.strategy {
        WcaseStrategy::Extreme => {
            let plus: Vec<f64> = overrides.iter().map(|o| o.expr.corner(config.k)).collect();
            let minus: Vec<f64> = overrides.iter().map(|o| o.expr.corner(-config.k)).collect();
            corners.push(WcaseCorner {
                index: 1,
                label: "all_plus".into(),
                values: plus,
            });
            corners.push(WcaseCorner {
                index: 2,
                label: "all_minus".into(),
                values: minus,
            });
        }
        WcaseStrategy::OneAtATime => {
            for (i, ov) in overrides.iter().enumerate() {
                let mut row_plus = nominal.clone();
                row_plus[i] = ov.expr.corner(config.k);
                corners.push(WcaseCorner {
                    index: corners.len(),
                    label: format!("{}_plus", ov.device_name),
                    values: row_plus,
                });

                let mut row_minus = nominal.clone();
                row_minus[i] = ov.expr.corner(-config.k);
                corners.push(WcaseCorner {
                    index: corners.len(),
                    label: format!("{}_minus", ov.device_name),
                    values: row_minus,
                });
            }
        }
    }

    corners
}

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

/// Run a worst-case experiment.
///
/// Mirrors [`crate::mc::run_mc`] but uses the deterministic corner list
/// instead of stochastic draws.  `eval_sample` is invoked once per corner with
/// a circuit clone whose overrides have been applied via
/// [`Circuit::set_device_param`].
pub fn run_wcase<F>(
    base_circuit: &Circuit,
    overrides: &[StatOverride],
    measure_names: Vec<String>,
    config: &WcaseConfig,
    mut eval_sample: F,
) -> Result<WcaseResults, SimError>
where
    F: FnMut(&Circuit, usize) -> Result<Vec<f64>, SimError>,
{
    let corners = enumerate_corners(overrides, config);
    let mut samples = McSampleResults::new(measure_names, corners.len());

    for corner in &corners {
        let mut sample_circuit = base_circuit.clone();
        for (ov, &val) in overrides.iter().zip(corner.values.iter()) {
            sample_circuit.set_device_param(&ov.device_name, &ov.param_key, val);
        }

        match eval_sample(&sample_circuit, corner.index) {
            Ok(row) if row.len() == samples.num_measures() => {
                samples.set_row(corner.index, &row);
            }
            Ok(row) => {
                let mut padded = row;
                padded.resize(samples.num_measures(), f64::NAN);
                samples.set_row(corner.index, &padded);
            }
            Err(e) => {
                samples.mark_failed(corner.index, e.to_string());
            }
        }
    }

    Ok(WcaseResults { samples, corners })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use incspice_core::{
        DeviceId, DeviceInstance, DeviceKind, Matching, NodeId, StatExpr, StatKind,
    };
    use incspice_solver::device::DeviceRegistry;

    fn divider() -> Circuit {
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

    fn agauss_override(name: &str, mean: f64, sigma: f64) -> StatOverride {
        StatOverride::new(
            name,
            "resistance",
            StatExpr {
                kind: StatKind::AGauss,
                mean,
                variation: sigma,
                nsig: 1.0,
                matching: Matching::Dev,
            },
        )
    }

    #[test]
    fn extreme_corners_three_samples() {
        let overrides = vec![
            agauss_override("R1", 1000.0, 50.0),
            agauss_override("R2", 1000.0, 50.0),
        ];
        let cfg = WcaseConfig {
            k: 1.0,
            strategy: WcaseStrategy::Extreme,
        };
        let corners = enumerate_corners(&overrides, &cfg);
        assert_eq!(corners.len(), 3);
        assert_eq!(corners[0].label, "nominal");
        assert_eq!(corners[1].label, "all_plus");
        assert_eq!(corners[2].label, "all_minus");
        assert_eq!(corners[0].values, vec![1000.0, 1000.0]);
        assert_eq!(corners[1].values, vec![1050.0, 1050.0]);
        assert_eq!(corners[2].values, vec![950.0, 950.0]);
    }

    #[test]
    fn one_at_a_time_count_is_2n_plus_1() {
        let overrides = vec![
            agauss_override("R1", 1000.0, 50.0),
            agauss_override("R2", 1000.0, 50.0),
            agauss_override("R3", 1000.0, 50.0),
        ];
        let cfg = WcaseConfig {
            k: 1.0,
            strategy: WcaseStrategy::OneAtATime,
        };
        let corners = enumerate_corners(&overrides, &cfg);
        assert_eq!(corners.len(), 7); // nominal + 2 * 3
        // Each non-nominal corner perturbs exactly one entry.
        let nom = &corners[0].values;
        for c in &corners[1..] {
            let differing = c
                .values
                .iter()
                .zip(nom.iter())
                .filter(|(a, b)| (*a - *b).abs() > 1e-12)
                .count();
            assert_eq!(differing, 1, "corner {} perturbs >1 override", c.label);
        }
    }

    #[test]
    fn wcase_runs_dc_op_and_records_voltages() {
        let base = divider();
        let reg = DeviceRegistry::new_default();
        let overrides = vec![agauss_override("R1", 1000.0, 100.0)];

        let cfg = WcaseConfig {
            k: 1.0,
            strategy: WcaseStrategy::Extreme,
        };

        let results = run_wcase(
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

        assert_eq!(results.samples.nsamples, 3);
        assert_eq!(results.corners.len(), 3);
        assert_eq!(results.samples.num_successes(), 3);

        // Nominal: V(2) = 5 * 1k / (1k+1k) = 2.5
        let nom = results.samples.values[0];
        assert!((nom - 2.5).abs() < 1e-9);

        // R1 = 1100: V(2) = 5 * 1k / (1.1k+1k) = 5*1000/2100 ≈ 2.380952
        let plus = results.samples.values[1];
        assert!((plus - (5_000.0 / 2_100.0)).abs() < 1e-9);

        // R1 = 900: V(2) = 5 * 1k / (0.9k+1k) = 5000/1900 ≈ 2.631579
        let minus = results.samples.values[2];
        assert!((minus - (5_000.0 / 1_900.0)).abs() < 1e-9);
    }
}
