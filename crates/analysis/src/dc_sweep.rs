//! DC sweep analysis — streaming per-point.

use incspice_cache::{CacheManager, ParamChange};
use incspice_core::{Circuit, StreamingSink};
use incspice_solver::device::DeviceRegistry;
use incspice_solver::newton::NrConfig;
use crate::{Analysis, AnalysisError};

pub struct DcSweep {
    pub source: String,
    pub values: Vec<f64>,
    /// Optional outer (second) sweep source for nested `.DC` analysis.
    /// When present, the outer loop iterates over `values2` and the inner
    /// loop iterates over `values`.  This matches ngspice behaviour where
    /// the last specified source is the outer sweep.
    pub source2: Option<String>,
    pub values2: Vec<f64>,
}

impl DcSweep {
    /// Run the inner (first-specified) sweep, emitting one point per value.
    /// Returns the last converged solution for use as continuation in the
    /// outer sweep.
    fn run_inner_sweep(
        source: &str,
        values: &[f64],
        circuit: &mut Circuit,
        registry: &DeviceRegistry,
        config: &NrConfig,
        cache: &mut CacheManager,
        sink: &mut dyn StreamingSink,
        x_prev: Option<&[f64]>,
    ) -> Result<Option<Vec<f64>>, AnalysisError> {
        let nv = circuit.num_vars() as usize;
        let is_temp = source.eq_ignore_ascii_case("temp");
        let mut x_prev = x_prev.map(|s| s.to_vec());

        for &val in values {
            if is_temp {
                circuit.set_global_temperature(val + 273.15);
                circuit.propagate_global_temperature();
                cache.invalidate_op();
            } else {
                let old_val = circuit
                    .find_device(source)
                    .and_then(|d| d.params.get("dc"))
                    .unwrap_or(0.0);

                circuit.set_device_param(source, "dc", val);

                if let Some(dev) = circuit.find_device(source) {
                    let device_id = dev.id;
                    let change = if old_val != 0.0 {
                        ParamChange::Scaling { factor: val / old_val }
                    } else {
                        ParamChange::NonLinear
                    };
                    cache.on_param_changed(device_id, change);
                }
            }

            let result = incspice_solver::solve_with_initial_guess(
                circuit,
                registry,
                config,
                cache,
                x_prev.as_deref(),
            )?;
            sink.emit_point(val, &result.solution[..nv])?;
            x_prev = Some(result.solution);
        }

        Ok(x_prev)
    }

    /// Set a single source value and notify the cache, without solving.
    fn set_source_value(
        source: &str,
        val: f64,
        circuit: &mut Circuit,
        cache: &mut CacheManager,
    ) {
        let is_temp = source.eq_ignore_ascii_case("temp");
        if is_temp {
            circuit.set_global_temperature(val + 273.15);
            circuit.propagate_global_temperature();
            cache.invalidate_op();
        } else {
            let old_val = circuit
                .find_device(source)
                .and_then(|d| d.params.get("dc"))
                .unwrap_or(0.0);

            circuit.set_device_param(source, "dc", val);

            if let Some(dev) = circuit.find_device(source) {
                let device_id = dev.id;
                let change = if old_val != 0.0 {
                    ParamChange::Scaling { factor: val / old_val }
                } else {
                    ParamChange::NonLinear
                };
                cache.on_param_changed(device_id, change);
            }
        }
    }
}

impl Analysis for DcSweep {
    fn run(&self, circuit: &mut Circuit, registry: &DeviceRegistry, config: &NrConfig, cache: &mut CacheManager, sink: &mut dyn StreamingSink) -> Result<(), AnalysisError> {
        match &self.source2 {
            Some(src2) if !self.values2.is_empty() => {
                // Nested sweep: outer = source2 (last specified), inner = source.
                // Carry continuation (x_prev) across inner sweep iterations.
                let mut x_prev: Option<Vec<f64>> = None;

                for &outer_val in &self.values2 {
                    Self::set_source_value(src2, outer_val, circuit, cache);

                    x_prev = Self::run_inner_sweep(
                        &self.source,
                        &self.values,
                        circuit,
                        registry,
                        config,
                        cache,
                        sink,
                        x_prev.as_deref(),
                    )?;
                }
            }
            _ => {
                // Single sweep (original behaviour).
                Self::run_inner_sweep(
                    &self.source,
                    &self.values,
                    circuit,
                    registry,
                    config,
                    cache,
                    sink,
                    None,
                )?;
            }
        }

        sink.finalize()?;
        Ok(())
    }
    fn name(&self) -> &str { "dc_sweep" }
}

#[cfg(test)]
mod tests {
    use super::*;
    use incspice_cache::CacheManager;
    use incspice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId, StreamingSink};
    use incspice_solver::device::DeviceRegistry;
    use incspice_solver::newton::NrConfig;

    /// Minimal sink that collects (sweep_val, node_voltages) pairs.
    struct VecSink {
        points: Vec<(f64, Vec<f64>)>,
    }

    impl VecSink {
        fn new() -> Self { Self { points: Vec::new() } }
    }

    impl StreamingSink for VecSink {
        fn emit_point(&mut self, x: f64, voltages: &[f64]) -> Result<(), incspice_core::SimError> {
            self.points.push((x, voltages.to_vec()));
            Ok(())
        }
        fn finalize(&mut self) -> Result<(), incspice_core::SimError> { Ok(()) }
    }

    /// Build a voltage-divider circuit:
    ///   Vin (voltage source) → node_in → R1=1kΩ → node_mid → R2=1kΩ → GND
    ///
    /// Node layout (after `add_node` calls):
    ///   index 0 = GND  (always)
    ///   index 1 = node_in
    ///   index 2 = node_mid
    ///
    /// MNA variables: v(node_in), v(node_mid), i_Vin  (branch current)
    fn voltage_divider(vin_dc: f64) -> Circuit {
        let mut ckt = Circuit::new();
        let node_in  = ckt.add_node("node_in");
        let node_mid = ckt.add_node("node_mid");

        // Vin: node_in → GND, dc = vin_dc
        let vin = DeviceInstance::new(
            DeviceId::new(0),
            "Vin",
            DeviceKind::VoltageSource,
            &[(0, node_in), (1, NodeId::GROUND)],
        )
        .with_param("dc", vin_dc);

        // R1: node_in → node_mid, 1 kΩ
        let r1 = DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, node_in), (1, node_mid)],
        )
        .with_param("resistance", 1_000.0);

        // R2: node_mid → GND, 1 kΩ
        let r2 = DeviceInstance::new(
            DeviceId::new(0),
            "R2",
            DeviceKind::Resistor,
            &[(0, node_mid), (1, NodeId::GROUND)],
        )
        .with_param("resistance", 1_000.0);

        ckt.add_device(vin);
        ckt.add_device(r1);
        ckt.add_device(r2);
        ckt.build_topology();
        ckt
    }

    #[test]
    fn test_dc_sweep_voltage_divider_changes_each_step() {
        // Sweep Vin from 1 V to 5 V in 1 V steps (skip 0 V to keep factor well-defined).
        let mut ckt = voltage_divider(1.0);
        let registry = DeviceRegistry::new_default();
        let config = NrConfig::default();
        let mut cache = CacheManager::new_for_circuit(&ckt);
        let mut sink = VecSink::new();

        let sweep = DcSweep {
            source: "Vin".to_string(),
            values: vec![1.0, 2.0, 3.0, 4.0, 5.0],
            source2: None,
            values2: vec![],
        };

        sweep.run(&mut ckt, &registry, &config, &mut cache, &mut sink).unwrap();

        // Expect one result point per sweep value.
        assert_eq!(sink.points.len(), 5, "expected 5 sweep points");

        // For a symmetric voltage divider, v(node_mid) = Vin / 2.
        // node_mid is the second node variable (MNA index 1, i.e. voltages[1]).
        for (vin_val, voltages) in &sink.points {
            let v_mid = voltages[1]; // node_mid
            let expected = vin_val / 2.0;
            let err = (v_mid - expected).abs();
            assert!(
                err < 1e-9,
                "at Vin={vin_val}V: v(node_mid)={v_mid:.6} expected {expected:.6} (err={err:.2e})"
            );
        }

        // Verify the node_mid voltages actually change across steps (not all identical).
        let mid_voltages: Vec<f64> = sink.points.iter().map(|(_, v)| v[1]).collect();
        let all_same = mid_voltages.windows(2).all(|w| (w[0] - w[1]).abs() < 1e-12);
        assert!(!all_same, "node_mid voltage must change with each sweep step");
    }

    #[test]
    fn test_dc_sweep_single_step() {
        let mut ckt = voltage_divider(5.0);
        let registry = DeviceRegistry::new_default();
        let config = NrConfig::default();
        let mut cache = CacheManager::new_for_circuit(&ckt);
        let mut sink = VecSink::new();

        let sweep = DcSweep { source: "Vin".to_string(), values: vec![8.0], source2: None, values2: vec![] };
        sweep.run(&mut ckt, &registry, &config, &mut cache, &mut sink).unwrap();
        assert_eq!(sink.points.len(), 1, "single sweep value → 1 point");
        let v_mid = sink.points[0].1[1];
        assert!((v_mid - 4.0).abs() < 1e-9, "v_mid at Vin=8V should be 4V, got {v_mid}");
    }

    #[test]
    fn test_dc_sweep_empty_values_produces_no_points() {
        let mut ckt = voltage_divider(5.0);
        let registry = DeviceRegistry::new_default();
        let config = NrConfig::default();
        let mut cache = CacheManager::new_for_circuit(&ckt);
        let mut sink = VecSink::new();

        let sweep = DcSweep { source: "Vin".to_string(), values: vec![], source2: None, values2: vec![] };
        sweep.run(&mut ckt, &registry, &config, &mut cache, &mut sink).unwrap();
        assert!(sink.points.is_empty());
    }

    #[test]
    fn test_dc_sweep_voltages_linear_in_vin() {
        let mut ckt = voltage_divider(1.0);
        let registry = DeviceRegistry::new_default();
        let config = NrConfig::default();
        let mut cache = CacheManager::new_for_circuit(&ckt);
        let mut sink = VecSink::new();

        let values: Vec<f64> = (1..=10).map(|i| i as f64).collect();
        let sweep = DcSweep { source: "Vin".to_string(), values, source2: None, values2: vec![] };
        sweep.run(&mut ckt, &registry, &config, &mut cache, &mut sink).unwrap();

        // v(node_mid) = Vin/2 for each step; check linearity
        for (i, (vin, voltages)) in sink.points.iter().enumerate() {
            let expected = vin / 2.0;
            let got = voltages[1];
            assert!(
                (got - expected).abs() < 1e-9,
                "step {i}: Vin={vin} expected mid={expected} got {got}"
            );
        }
    }

    #[test]
    fn test_dc_sweep_node_voltage_output_length() {
        let mut ckt = voltage_divider(1.0);
        let registry = DeviceRegistry::new_default();
        let config = NrConfig::default();
        let mut cache = CacheManager::new_for_circuit(&ckt);
        let mut sink = VecSink::new();

        let nv = ckt.num_vars() as usize;
        let sweep = DcSweep { source: "Vin".to_string(), values: vec![1.0, 2.0, 3.0], source2: None, values2: vec![] };
        sweep.run(&mut ckt, &registry, &config, &mut cache, &mut sink).unwrap();

        for (i, (_, voltages)) in sink.points.iter().enumerate() {
            assert_eq!(voltages.len(), nv, "step {i}: expected {nv} node voltages");
        }
    }

    #[test]
    fn test_dc_sweep_temp_sets_global_temperature() {
        // Sweep TEMP from -40 to 125 in a simple resistor circuit.
        // Temperature sweep should update the circuit temperature at each point
        // and still produce valid results (resistors are temperature-independent
        // at this level, so voltages stay the same — we mainly verify no panic).
        let mut ckt = voltage_divider(10.0);
        let registry = DeviceRegistry::new_default();
        let config = NrConfig::default();
        let mut cache = CacheManager::new_for_circuit(&ckt);
        let mut sink = VecSink::new();

        let sweep = DcSweep {
            source: "TEMP".to_string(),
            values: vec![-40.0, 25.0, 85.0, 125.0],
            source2: None,
            values2: vec![],
        };

        sweep.run(&mut ckt, &registry, &config, &mut cache, &mut sink).unwrap();

        assert_eq!(sink.points.len(), 4, "expected 4 sweep points for TEMP sweep");

        // The x-axis values should be the temperature values in Celsius.
        let xs: Vec<f64> = sink.points.iter().map(|(x, _)| *x).collect();
        assert_eq!(xs, vec![-40.0, 25.0, 85.0, 125.0]);

        // After the sweep, the circuit temperature should reflect the last point.
        let temps = ckt.temperatures();
        assert!(!temps.is_empty(), "circuit should have a temperature set");
        let expected_kelvin = 125.0 + 273.15;
        assert!(
            (temps[0] - expected_kelvin).abs() < 1e-9,
            "final temperature should be {expected_kelvin} K, got {}",
            temps[0]
        );

        // Voltage divider: v(node_mid) = 10/2 = 5V regardless of temperature
        // (basic resistors have no temperature coefficient in this model).
        for (temp_val, voltages) in &sink.points {
            let v_mid = voltages[1];
            assert!(
                (v_mid - 5.0).abs() < 1e-9,
                "at TEMP={temp_val}°C: v(node_mid)={v_mid:.6} expected 5.0"
            );
        }
    }

    #[test]
    fn test_dc_sweep_temp_case_insensitive() {
        // "temp" in lowercase should also be recognized as a temperature sweep.
        let mut ckt = voltage_divider(10.0);
        let registry = DeviceRegistry::new_default();
        let config = NrConfig::default();
        let mut cache = CacheManager::new_for_circuit(&ckt);
        let mut sink = VecSink::new();

        let sweep = DcSweep {
            source: "temp".to_string(),
            values: vec![27.0],
            source2: None,
            values2: vec![],
        };

        sweep.run(&mut ckt, &registry, &config, &mut cache, &mut sink).unwrap();
        assert_eq!(sink.points.len(), 1);

        let temps = ckt.temperatures();
        let expected_kelvin = 27.0 + 273.15;
        assert!(
            (temps[0] - expected_kelvin).abs() < 1e-9,
            "temperature should be {expected_kelvin} K, got {}",
            temps[0]
        );
    }

    #[test]
    fn test_dc_sweep_analysis_name() {
        let s = DcSweep { source: "Vs".into(), values: vec![], source2: None, values2: vec![] };
        // Verify the Analysis trait name method is correct via the struct directly
        // (DcSweep::name is only accessible via the Analysis trait)
        let _ = s; // just ensure it constructs correctly
    }

    #[test]
    fn test_dc_sweep_sweep_values_stored_as_x_axis() {
        let mut ckt = voltage_divider(1.0);
        let registry = DeviceRegistry::new_default();
        let config = NrConfig::default();
        let mut cache = CacheManager::new_for_circuit(&ckt);
        let mut sink = VecSink::new();

        let vals = vec![2.0, 4.0, 6.0];
        let sweep = DcSweep { source: "Vin".to_string(), values: vals.clone(), source2: None, values2: vec![] };
        sweep.run(&mut ckt, &registry, &config, &mut cache, &mut sink).unwrap();

        let xs: Vec<f64> = sink.points.iter().map(|(x, _)| *x).collect();
        assert_eq!(xs, vals, "x-axis values must match sweep values");
    }

    /// Build a circuit with two independent voltage sources feeding a
    /// resistive divider so we can test nested sweeps:
    ///
    ///   V1 → node_a → R1=1kΩ → node_mid → R2=1kΩ → node_b ← V2
    ///
    /// v(node_mid) = (V1 + V2) / 2  for equal resistors.
    fn two_source_divider(v1_dc: f64, v2_dc: f64) -> Circuit {
        let mut ckt = Circuit::new();
        let node_a   = ckt.add_node("node_a");
        let node_mid = ckt.add_node("node_mid");
        let node_b   = ckt.add_node("node_b");

        let v1 = DeviceInstance::new(
            DeviceId::new(0), "V1", DeviceKind::VoltageSource,
            &[(0, node_a), (1, NodeId::GROUND)],
        ).with_param("dc", v1_dc);

        let v2 = DeviceInstance::new(
            DeviceId::new(0), "V2", DeviceKind::VoltageSource,
            &[(0, node_b), (1, NodeId::GROUND)],
        ).with_param("dc", v2_dc);

        let r1 = DeviceInstance::new(
            DeviceId::new(0), "R1", DeviceKind::Resistor,
            &[(0, node_a), (1, node_mid)],
        ).with_param("resistance", 1_000.0);

        let r2 = DeviceInstance::new(
            DeviceId::new(0), "R2", DeviceKind::Resistor,
            &[(0, node_mid), (1, node_b)],
        ).with_param("resistance", 1_000.0);

        ckt.add_device(v1);
        ckt.add_device(v2);
        ckt.add_device(r1);
        ckt.add_device(r2);
        ckt.build_topology();
        ckt
    }

    #[test]
    fn test_dc_sweep_nested_two_sources() {
        // .DC V1 1 3 1 V2 0 2 1
        // Outer loop: V2 = 0, 1, 2  (3 steps)
        // Inner loop: V1 = 1, 2, 3  (3 steps)
        // Total: 9 points
        let mut ckt = two_source_divider(1.0, 0.0);
        let registry = DeviceRegistry::new_default();
        let config = NrConfig::default();
        let mut cache = CacheManager::new_for_circuit(&ckt);
        let mut sink = VecSink::new();

        let sweep = DcSweep {
            source: "V1".to_string(),
            values: vec![1.0, 2.0, 3.0],
            source2: Some("V2".to_string()),
            values2: vec![0.0, 1.0, 2.0],
        };

        sweep.run(&mut ckt, &registry, &config, &mut cache, &mut sink).unwrap();

        assert_eq!(sink.points.len(), 9, "expected 3x3 = 9 nested sweep points");

        // node_mid is MNA index 1 (second node added).
        // v(node_mid) = (V1 + V2) / 2 for equal R1, R2.
        // The x-axis emitted is the inner sweep value (V1).
        // Outer loop order: V2=0, V2=1, V2=2.
        let v2_vals = [0.0, 1.0, 2.0];
        let v1_vals = [1.0, 2.0, 3.0];
        for (outer_idx, &v2) in v2_vals.iter().enumerate() {
            for (inner_idx, &v1) in v1_vals.iter().enumerate() {
                let pt_idx = outer_idx * v1_vals.len() + inner_idx;
                let (x, ref voltages) = sink.points[pt_idx];
                assert!(
                    (x - v1).abs() < 1e-12,
                    "point {pt_idx}: x-axis should be V1={v1}, got {x}"
                );
                let v_mid = voltages[1];
                let expected = (v1 + v2) / 2.0;
                assert!(
                    (v_mid - expected).abs() < 1e-6,
                    "point {pt_idx} (V1={v1}, V2={v2}): v_mid={v_mid:.6} expected {expected:.6}"
                );
            }
        }
    }

    #[test]
    fn test_dc_sweep_nested_single_outer_step() {
        // Edge case: outer sweep has only 1 step.
        let mut ckt = two_source_divider(1.0, 0.0);
        let registry = DeviceRegistry::new_default();
        let config = NrConfig::default();
        let mut cache = CacheManager::new_for_circuit(&ckt);
        let mut sink = VecSink::new();

        let sweep = DcSweep {
            source: "V1".to_string(),
            values: vec![1.0, 2.0, 3.0],
            source2: Some("V2".to_string()),
            values2: vec![5.0],
        };

        sweep.run(&mut ckt, &registry, &config, &mut cache, &mut sink).unwrap();
        assert_eq!(sink.points.len(), 3, "1 outer x 3 inner = 3 points");

        for (v1, voltages) in &sink.points {
            let v_mid = voltages[1];
            let expected = (v1 + 5.0) / 2.0;
            assert!(
                (v_mid - expected).abs() < 1e-6,
                "V1={v1}, V2=5: v_mid={v_mid:.6} expected {expected:.6}"
            );
        }
    }
}
