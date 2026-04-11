//! DC sensitivity analysis — finite-difference direct method.
//!
//! For each requested parameter, perturbs its value by a small `h`, re-runs
//! the DC operating point, and computes a forward-difference derivative.
//!
//! `absolute = (out(p + h) - out(p)) / h`
//! `relative  = (p / out) * absolute`

use bigospice_core::{Circuit, DeviceKind, SimError, SimOptions};
use bigospice_device::DeviceRegistry;

use crate::dc_op::run_dc_op_with_config;

/// Which circuit output to compute sensitivities for.
#[derive(Debug, Clone)]
pub enum SensOutput {
    /// Node voltage `V(name)`.
    NodeVoltage(String),
    /// Branch current through a voltage source `I(vname)`.
    BranchCurrent(String),
}

/// Configuration for a sensitivity run.
#[derive(Debug, Clone)]
pub struct SensConfig {
    /// The output variable to differentiate.
    pub output: SensOutput,
    /// Device names whose primary parameter is perturbed (e.g. `"R1"`, `"Vcc"`).
    pub params: Vec<String>,
}

/// One sensitivity entry for a single parameter.
#[derive(Debug, Clone)]
pub struct SensEntry {
    pub param_name: String,
    /// Absolute sensitivity: `∂output / ∂p`.
    pub absolute: f64,
    /// Relative sensitivity: `(p / output) * ∂output / ∂p`.
    /// Zero when `|output| < 1e-20`.
    pub relative: f64,
}

/// Result of a sensitivity analysis.
#[derive(Debug, Clone)]
pub struct SensResult {
    /// Baseline output value at the unperturbed operating point.
    pub output_value: f64,
    /// Sensitivity entries in the same order as `SensConfig::params`.
    pub sensitivities: Vec<SensEntry>,
}

// ---------------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------------

/// Run DC sensitivity analysis with default solver settings.
pub fn run_sens_dc(circuit: &Circuit, cfg: &SensConfig) -> Result<SensResult, SimError> {
    run_sens_dc_with_options(circuit, cfg, &SimOptions::default())
}

/// Run DC sensitivity analysis with explicit simulation options.
pub fn run_sens_dc_with_options(
    circuit: &Circuit,
    cfg: &SensConfig,
    opts: &SimOptions,
) -> Result<SensResult, SimError> {
    use bigospice_solver::NrConfig;

    let registry = DeviceRegistry::new_default();
    let nr_cfg = NrConfig::from(opts);

    // --- Baseline DC OP ---
    let base_out = run_dc_op_with_config(circuit, &registry, Some(nr_cfg.clone()), None)?;
    let output_value = extract_output_from_result(circuit, &base_out.result, &cfg.output)?;

    // --- Per-parameter forward-difference ---
    let sensitivities = cfg
        .params
        .iter()
        .map(|param_name| {
            // Find the device and its primary parameter key + value.
            let dev = circuit
                .find_device(param_name)
                .ok_or_else(|| SimError::Parse(format!("SENS: device '{param_name}' not found")))?;

            let (param_key, p0) = primary_param(dev.kind, &dev.params)?;

            // Skip devices that have no meaningful DC sensitivity (C, L).
            if p0 == 0.0 && matches!(dev.kind, DeviceKind::Capacitor | DeviceKind::Inductor) {
                return Ok(SensEntry {
                    param_name: param_name.clone(),
                    absolute: 0.0,
                    relative: 0.0,
                });
            }

            let h = perturbation(p0);

            // Clone and perturb.
            let mut perturbed = circuit.clone();
            perturbed.set_device_param(param_name, &param_key, p0 + h);

            let pert_out =
                run_dc_op_with_config(&perturbed, &registry, Some(nr_cfg.clone()), None)?;
            let out_plus = extract_output_from_result(&perturbed, &pert_out.result, &cfg.output)?;

            let absolute = (out_plus - output_value) / h;
            let relative = if output_value.abs() > 1e-20 {
                (p0 / output_value) * absolute
            } else {
                0.0
            };

            Ok(SensEntry {
                param_name: param_name.clone(),
                absolute,
                relative,
            })
        })
        .collect::<Result<Vec<_>, SimError>>()?;

    Ok(SensResult {
        output_value,
        sensitivities,
    })
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Compute the perturbation step: `h = max(1e-8, 1e-3 * |p0|)`.
#[inline]
fn perturbation(p0: f64) -> f64 {
    f64::max(1e-8, 1e-3 * p0.abs())
}

/// Return `(param_key, value)` for the primary DC parameter of a device kind.
fn primary_param(
    kind: DeviceKind,
    params: &bigospice_core::ParamMap,
) -> Result<(String, f64), SimError> {
    let key = match kind {
        DeviceKind::Resistor => "resistance",
        DeviceKind::Capacitor => "capacitance",
        DeviceKind::Inductor => "inductance",
        DeviceKind::VoltageSource => "dc",
        DeviceKind::CurrentSource => "dc",
        DeviceKind::Diode => "is",
        _ => {
            return Err(SimError::Parse(format!(
                "SENS: unsupported device kind {kind:?} for sensitivity"
            )))
        }
    };

    let val = params
        .get(key)
        .ok_or_else(|| SimError::Parse(format!("SENS: device has no '{key}' parameter")))?;

    Ok((key.to_string(), val))
}

/// Extract the scalar output value from a DC OP result.
fn extract_output_from_result(
    _circuit: &Circuit,
    result: &crate::result::DcOpResult,
    output: &SensOutput,
) -> Result<f64, SimError> {
    match output {
        SensOutput::NodeVoltage(name) => {
            let lower = name.to_lowercase();
            if lower == "0" || lower == "gnd" {
                return Ok(0.0);
            }
            result
                .node_voltages
                .iter()
                .find(|(n, _)| n.to_lowercase() == lower)
                .map(|(_, v)| *v)
                .ok_or_else(|| SimError::Parse(format!("SENS: node '{name}' not found in result")))
        }
        SensOutput::BranchCurrent(vname) => {
            let lower = vname.to_lowercase();
            result
                .branch_currents
                .iter()
                .find(|(n, _)| n.to_lowercase() == lower)
                .map(|(_, i)| *i)
                .ok_or_else(|| {
                    SimError::Parse(format!(
                        "SENS: branch current for '{vname}' not found in result"
                    ))
                })
        }
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use bigospice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};

    fn voltage_divider(r1: f64, r2: f64, vcc: f64) -> Circuit {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let n2 = ckt.add_node("2");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "Vcc", DeviceKind::VoltageSource, &[
                (0, n1),
                (1, NodeId::GROUND),
            ])
            .with_param("dc", vcc),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "R1", DeviceKind::Resistor, &[
                (0, n1),
                (1, n2),
            ])
            .with_param("resistance", r1),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "R2", DeviceKind::Resistor, &[
                (0, n2),
                (1, NodeId::GROUND),
            ])
            .with_param("resistance", r2),
        );
        ckt.build_topology();
        ckt
    }

    #[test]
    fn perturbation_step() {
        assert!((perturbation(1e3) - 1.0).abs() < 1e-12);
        assert!((perturbation(0.0) - 1e-8).abs() < 1e-20);
        assert!((perturbation(-1e3) - 1.0).abs() < 1e-12);
    }

    #[test]
    fn extract_node_voltage() {
        let ckt = voltage_divider(1e3, 2e3, 3.0);
        let cfg = SensConfig {
            output: SensOutput::NodeVoltage("2".into()),
            params: vec![],
        };
        let result = run_sens_dc(&ckt, &cfg).unwrap();
        // Vout = Vcc * R2 / (R1 + R2) = 3 * 2000 / 3000 = 2.0
        assert!((result.output_value - 2.0).abs() < 1e-6, "Vout={}", result.output_value);
    }

    #[test]
    fn extract_ground_node() {
        let ckt = voltage_divider(1e3, 2e3, 3.0);
        let cfg = SensConfig {
            output: SensOutput::NodeVoltage("0".into()),
            params: vec![],
        };
        let result = run_sens_dc(&ckt, &cfg).unwrap();
        assert_eq!(result.output_value, 0.0);
    }

    #[test]
    fn device_not_found_error() {
        let ckt = voltage_divider(1e3, 2e3, 3.0);
        let cfg = SensConfig {
            output: SensOutput::NodeVoltage("2".into()),
            params: vec!["Rx".into()],
        };
        assert!(run_sens_dc(&ckt, &cfg).is_err());
    }
}
