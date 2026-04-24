//! DC sensitivity analysis using forward finite differences (§2.3).
//!
//! For each device parameter `p`, the sensitivity of every node voltage `V`
//! is estimated as:
//!
//!   ∂V/∂p ≈ (V(p + h) − V(p)) / h
//!
//! where `h = max(1e-8, 1e-3 * |p|)`.
//!
//! Absolute sensitivity: `dV/dp`
//! Relative sensitivity: `(dV/dp) * (p / V)` (zero where |V| < 1e-15)

use incspice_cache::CacheManager;
use incspice_core::{Circuit, StreamingSink};
use incspice_solver::device::DeviceRegistry;
use incspice_solver::newton::NrConfig;
use crate::{Analysis, AnalysisError};

// ---------------------------------------------------------------------------
// Public result types
// ---------------------------------------------------------------------------

/// Sensitivity of all node voltages to one device parameter.
#[derive(Debug, Clone)]
pub struct DeviceSensitivity {
    /// Device name.
    pub device: String,
    /// Parameter name.
    pub param: String,
    /// Absolute sensitivity `∂V_i/∂p` for each MNA node voltage index.
    pub absolute: Vec<f64>,
    /// Relative sensitivity `(∂V_i/∂p) * (p / V_i)` (0 where |V_i| < 1e-15).
    pub relative: Vec<f64>,
}

/// Complete result of a DC sensitivity analysis.
#[derive(Debug, Clone)]
pub struct SensitivityResult {
    /// Nominal node voltages (length = `circuit.num_vars()`).
    pub nominal: Vec<f64>,
    /// One entry per (device, parameter) pair.
    pub sensitivities: Vec<DeviceSensitivity>,
}

// ---------------------------------------------------------------------------
// Core computation
// ---------------------------------------------------------------------------

/// Run DC sensitivity analysis via forward finite differences.
///
/// 1. Solve the nominal DC operating point.
/// 2. For each device parameter, perturb it by `h` and re-solve.
/// 3. Compute `∂V/∂p = (V_up − V_nominal) / h`.
pub fn run_dc_sensitivity(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    config: &NrConfig,
    cache: &mut CacheManager,
) -> Result<SensitivityResult, incspice_core::SimError> {
    // 1. Nominal operating point.
    let nr_nominal = incspice_solver::solve(circuit, registry, config, cache)?;
    let nv = circuit.num_vars() as usize;
    let v_nominal: Vec<f64> = nr_nominal.solution[..nv].to_vec();

    // 2. Collect (device_name, param_name, nominal_value) triples first, so we
    //    don't borrow `circuit` while also cloning it in the loop body.
    let perturbations: Vec<(String, String, f64)> = circuit
        .devices()
        .iter()
        .flat_map(|dev| {
            dev.params
                .iter()
                .map(move |(pname, pval)| {
                    (dev.name.clone(), pname.to_string(), pval)
                })
        })
        .collect();

    // 3. Forward differences per parameter.
    let mut sensitivities = Vec::with_capacity(perturbations.len());

    for (dev_name, param_name, nominal_val) in &perturbations {
        let h = (1e-8_f64).max(1e-3 * nominal_val.abs());

        // Clone circuit, perturb the parameter.
        let mut circuit_up = circuit.clone();
        circuit_up.set_device_param(dev_name, param_name, nominal_val + h);

        // Re-solve.
        let nr_up = incspice_solver::solve(&circuit_up, registry, config, cache)?;
        let v_up: &[f64] = &nr_up.solution[..nv];

        // ∂V/∂p (absolute).
        let absolute: Vec<f64> = v_up
            .iter()
            .zip(&v_nominal)
            .map(|(vup, vnom)| (vup - vnom) / h)
            .collect();

        // Relative sensitivity: (∂V/∂p) * (p / V).
        let relative: Vec<f64> = absolute
            .iter()
            .zip(&v_nominal)
            .map(|(dv, v)| {
                if v.abs() > 1e-15 {
                    dv * nominal_val / v
                } else {
                    0.0
                }
            })
            .collect();

        sensitivities.push(DeviceSensitivity {
            device: dev_name.clone(),
            param: param_name.clone(),
            absolute,
            relative,
        });
    }

    Ok(SensitivityResult {
        nominal: v_nominal,
        sensitivities,
    })
}

// ---------------------------------------------------------------------------
// Analysis trait impl
// ---------------------------------------------------------------------------

/// DC sensitivity analysis driver.
pub struct Sensitivity {
    /// Output variable specifier (e.g. `"V(out)"`).  Currently unused but
    /// stored for future filtering of the sink output.
    pub output: String,
}

impl Analysis for Sensitivity {
    fn run(
        &self,
        circuit: &mut Circuit,
        registry: &DeviceRegistry,
        config: &NrConfig,
        cache: &mut CacheManager,
        sink: &mut dyn StreamingSink,
    ) -> Result<(), AnalysisError> {
        let result = run_dc_sensitivity(circuit, registry, config, cache)?;

        // Point 0 = nominal operating point voltages.
        sink.emit_point(0.0, &result.nominal)?;

        // Points 1..N = absolute sensitivity vectors.
        for (i, sens) in result.sensitivities.iter().enumerate() {
            sink.emit_point(i as f64 + 1.0, &sens.absolute)?;
        }

        sink.finalize()?;
        Ok(())
    }

    fn name(&self) -> &str {
        "sensitivity"
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use incspice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
    use incspice_solver::device::DeviceRegistry;

    /// Build a simple voltage-divider circuit:
    ///
    /// ```text
    ///  Vdd (5 V) ─── R1 ─── mid ─── R2 ─── GND
    /// ```
    ///
    /// `V(mid) = Vdd * R2 / (R1 + R2)`
    /// `∂V(mid)/∂R2 = Vdd * R1 / (R1 + R2)^2`
    fn voltage_divider(r1: f64, r2: f64, vdd: f64) -> Circuit {
        let mut ckt = Circuit::new();
        let n_vdd = ckt.add_node("vdd");
        let n_mid = ckt.add_node("mid");

        // Voltage source: vdd → GND
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "Vdd",
                DeviceKind::VoltageSource,
                &[(0, n_vdd), (1, NodeId::GROUND)],
            )
            .with_param("dc", vdd),
        );

        // R1: vdd → mid
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "R1",
                DeviceKind::Resistor,
                &[(0, n_vdd), (1, n_mid)],
            )
            .with_param("resistance", r1),
        );

        // R2: mid → GND
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "R2",
                DeviceKind::Resistor,
                &[(0, n_mid), (1, NodeId::GROUND)],
            )
            .with_param("resistance", r2),
        );

        ckt.build_topology();
        ckt
    }

    #[test]
    fn test_dc_sens_nominal_voltages() {
        // R1 = R2 = 1 kΩ, Vdd = 5 V → V(mid) = 2.5 V
        let ckt = voltage_divider(1e3, 1e3, 5.0);
        let reg = DeviceRegistry::new_default();
        let config = NrConfig::default();
        let mut cache = CacheManager::new();

        let result = run_dc_sensitivity(&ckt, &reg, &config, &mut cache).unwrap();

        // num_vars = 2: node "vdd" (idx 0) and node "mid" (idx 1)
        assert_eq!(result.nominal.len(), 2);
        let v_vdd = result.nominal[0];
        let v_mid = result.nominal[1];

        assert!((v_vdd - 5.0).abs() < 1e-9, "V(vdd) should be 5 V, got {v_vdd}");
        assert!((v_mid - 2.5).abs() < 1e-9, "V(mid) should be 2.5 V, got {v_mid}");
    }

    #[test]
    fn test_dc_sens_resistor_value() {
        // Voltage divider: R1 = 1 kΩ, R2 = 1 kΩ, Vdd = 5 V
        // V(mid) = 5 * 1000 / (1000 + 1000) = 2.5 V
        //
        // Analytical ∂V(mid)/∂R2 = Vdd * R1 / (R1 + R2)^2
        //                         = 5 * 1000 / (2000^2) = 5000 / 4000000 = 1.25e-3
        let r1 = 1e3;
        let r2 = 1e3;
        let vdd = 5.0;
        let ckt = voltage_divider(r1, r2, vdd);
        let reg = DeviceRegistry::new_default();
        let config = NrConfig::default();
        let mut cache = CacheManager::new();

        let result = run_dc_sensitivity(&ckt, &reg, &config, &mut cache).unwrap();

        // Find sensitivity entry for R2 / resistance
        let r2_entry = result
            .sensitivities
            .iter()
            .find(|s| s.device == "R2" && s.param == "resistance")
            .expect("R2 resistance sensitivity not found");

        // mid node is index 1 (nodes: [vdd=0, mid=1])
        let dv_mid_dr2 = r2_entry.absolute[1];
        let expected = vdd * r1 / (r1 + r2).powi(2);

        assert!(
            (dv_mid_dr2 - expected).abs() < 1e-6,
            "∂V(mid)/∂R2: got {dv_mid_dr2:.6e}, expected {expected:.6e}"
        );
    }

    #[test]
    fn test_dc_sens_vdd_node_sensitivity_to_vsource() {
        // The vdd node is driven by Vdd source. ∂V(vdd)/∂Vdd_dc should be ≈ 1.
        let ckt = voltage_divider(1e3, 1e3, 5.0);
        let reg = DeviceRegistry::new_default();
        let config = NrConfig::default();
        let mut cache = CacheManager::new();

        let result = run_dc_sensitivity(&ckt, &reg, &config, &mut cache).unwrap();

        let vdd_entry = result
            .sensitivities
            .iter()
            .find(|s| s.device == "Vdd" && s.param == "dc")
            .expect("Vdd dc sensitivity not found");

        // vdd node is index 0
        let dv_vdd_dvdd = vdd_entry.absolute[0];
        assert!(
            (dv_vdd_dvdd - 1.0).abs() < 1e-6,
            "∂V(vdd)/∂Vdd_dc should be 1.0, got {dv_vdd_dvdd}"
        );
    }

    #[test]
    fn test_dc_sens_returns_entry_per_parameter() {
        let ckt = voltage_divider(1e3, 1e3, 5.0);
        let reg = DeviceRegistry::new_default();
        let config = NrConfig::default();
        let mut cache = CacheManager::new();

        let result = run_dc_sensitivity(&ckt, &reg, &config, &mut cache).unwrap();

        // We have: Vdd (dc), R1 (resistance), R2 (resistance) → at least 3 entries
        assert!(
            result.sensitivities.len() >= 3,
            "expected ≥3 sensitivity entries, got {}",
            result.sensitivities.len()
        );

        // Every entry should have absolute/relative vectors matching nominal length
        for entry in &result.sensitivities {
            assert_eq!(entry.absolute.len(), result.nominal.len());
            assert_eq!(entry.relative.len(), result.nominal.len());
        }
    }

    /// `.sens V(mid)` on a voltage divider with unequal resistors.
    ///
    /// R1 = 2 kΩ, R2 = 3 kΩ, Vdd = 10 V
    /// V(mid) = 10 * 3000 / (2000 + 3000) = 6 V
    /// ∂V(mid)/∂R1 = -Vdd * R2 / (R1 + R2)^2 = -10 * 3000 / 25e6 = -1.2e-3
    /// ∂V(mid)/∂R2 =  Vdd * R1 / (R1 + R2)^2 = 10 * 2000 / 25e6 =  0.8e-3
    #[test]
    fn sens_dc_divider() {
        let r1 = 2e3;
        let r2 = 3e3;
        let vdd = 10.0;
        let ckt = voltage_divider(r1, r2, vdd);
        let reg = DeviceRegistry::new_default();
        let config = NrConfig::default();
        let mut cache = CacheManager::new();

        let result = run_dc_sensitivity(&ckt, &reg, &config, &mut cache).unwrap();

        // Verify nominal V(mid)
        let v_mid = result.nominal[1];
        let expected_v = vdd * r2 / (r1 + r2);
        assert!(
            (v_mid - expected_v).abs() < 1e-8,
            "V(mid) = {v_mid}, expected {expected_v}"
        );

        // ∂V(mid)/∂R1
        let r1_entry = result
            .sensitivities
            .iter()
            .find(|s| s.device == "R1" && s.param == "resistance")
            .expect("R1 sensitivity not found");
        let dv_dr1 = r1_entry.absolute[1];
        let expected_dr1 = -vdd * r2 / (r1 + r2).powi(2);
        assert!(
            (dv_dr1 - expected_dr1).abs() < 1e-6,
            "∂V(mid)/∂R1: got {dv_dr1:.6e}, expected {expected_dr1:.6e}"
        );

        // ∂V(mid)/∂R2
        let r2_entry = result
            .sensitivities
            .iter()
            .find(|s| s.device == "R2" && s.param == "resistance")
            .expect("R2 sensitivity not found");
        let dv_dr2 = r2_entry.absolute[1];
        let expected_dr2 = vdd * r1 / (r1 + r2).powi(2);
        assert!(
            (dv_dr2 - expected_dr2).abs() < 1e-6,
            "∂V(mid)/∂R2: got {dv_dr2:.6e}, expected {expected_dr2:.6e}"
        );

        // Relative sensitivity of V(mid) to R2: (∂V/∂R2) * (R2 / V)
        let rel_r2 = r2_entry.relative[1];
        let expected_rel = expected_dr2 * r2 / expected_v;
        assert!(
            (rel_r2 - expected_rel).abs() < 5e-3,
            "relative sens of V(mid) to R2: got {rel_r2:.6e}, expected {expected_rel:.6e}"
        );
    }

    /// DC sensitivity of a BJT differential pair.
    ///
    /// ```text
    ///         Vcc (5V)
    ///          |    |
    ///         Rc1  Rc2   (1kΩ each)
    ///          |    |
    ///         out1  out2
    ///          |    |
    ///       Q1(c)  Q2(c)
    ///       Q1(b)  Q2(b) ← Vb1, Vb2 (0.7V each for balanced)
    ///       Q1(e)  Q2(e)
    ///          \   /
    ///           Re   (10kΩ tail resistor)
    ///           |
    ///          GND
    /// ```
    ///
    /// With matched transistors and equal base voltages (0.7 V), the circuit is
    /// balanced and each collector sits near Vcc - Ic*Rc.
    ///
    /// We verify that sensitivity analysis runs on a circuit with BJTs and that
    /// the `bf` (forward beta) sensitivity is finite and non-zero for the output
    /// nodes.
    #[test]
    fn bjt_diffpair_dc_sens() {
        let mut ckt = Circuit::new();
        let n_vcc = ckt.add_node("vcc");
        let n_out1 = ckt.add_node("out1");
        let n_out2 = ckt.add_node("out2");
        let n_b1 = ckt.add_node("b1");
        let n_b2 = ckt.add_node("b2");
        let n_tail = ckt.add_node("tail");

        // Vcc = 5 V
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "Vcc",
                DeviceKind::VoltageSource,
                &[(0, n_vcc), (1, NodeId::GROUND)],
            )
            .with_param("dc", 5.0),
        );

        // Base bias sources: Vb1 = Vb2 = 0.7 V (balanced pair)
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "Vb1",
                DeviceKind::VoltageSource,
                &[(0, n_b1), (1, NodeId::GROUND)],
            )
            .with_param("dc", 0.7),
        );
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "Vb2",
                DeviceKind::VoltageSource,
                &[(0, n_b2), (1, NodeId::GROUND)],
            )
            .with_param("dc", 0.7),
        );

        // Rc1: vcc → out1
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "Rc1",
                DeviceKind::Resistor,
                &[(0, n_vcc), (1, n_out1)],
            )
            .with_param("resistance", 1e3),
        );

        // Rc2: vcc → out2
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "Rc2",
                DeviceKind::Resistor,
                &[(0, n_vcc), (1, n_out2)],
            )
            .with_param("resistance", 1e3),
        );

        // Q1: NPN BJT (collector=out1, base=b1, emitter=tail)
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "Q1",
                DeviceKind::BjtNpn,
                &[(0, n_out1), (1, n_b1), (2, n_tail)],
            )
            .with_param("is", 1e-15)
            .with_param("bf", 100.0),
        );

        // Q2: NPN BJT (collector=out2, base=b2, emitter=tail)
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "Q2",
                DeviceKind::BjtNpn,
                &[(0, n_out2), (1, n_b2), (2, n_tail)],
            )
            .with_param("is", 1e-15)
            .with_param("bf", 100.0),
        );

        // Re: tail resistor to GND
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "Re",
                DeviceKind::Resistor,
                &[(0, n_tail), (1, NodeId::GROUND)],
            )
            .with_param("resistance", 10e3),
        );

        ckt.build_topology();
        let reg = DeviceRegistry::new_default();
        let config = NrConfig::default();
        let mut cache = CacheManager::new();

        let result = run_dc_sensitivity(&ckt, &reg, &config, &mut cache).unwrap();

        // The analysis should produce finite nominal voltages.
        for (i, v) in result.nominal.iter().enumerate() {
            assert!(v.is_finite(), "nominal voltage[{i}] is not finite: {v}");
        }

        // Find Q1's BF sensitivity — it should be finite and non-zero.
        let q1_bf = result
            .sensitivities
            .iter()
            .find(|s| s.device == "Q1" && s.param == "bf");
        assert!(
            q1_bf.is_some(),
            "sensitivity entry for Q1/bf not found; entries: {:?}",
            result
                .sensitivities
                .iter()
                .map(|s| format!("{}/{}", s.device, s.param))
                .collect::<Vec<_>>()
        );
        let q1_bf = q1_bf.unwrap();
        // At least one output node should have non-zero sensitivity to BF.
        let any_nonzero = q1_bf.absolute.iter().any(|v| v.abs() > 1e-15);
        assert!(
            any_nonzero,
            "∂V/∂BF for Q1 should be non-zero for at least one node, got {:?}",
            q1_bf.absolute
        );
        // All values must be finite.
        for (i, v) in q1_bf.absolute.iter().enumerate() {
            assert!(
                v.is_finite(),
                "∂V[{i}]/∂BF(Q1) is not finite: {v}"
            );
        }
    }
}
