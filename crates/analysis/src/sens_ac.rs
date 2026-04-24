//! `.SENS … AC` — frequency-dependent sensitivity analysis.
//!
//! Extends the DC sensitivity analysis (`crates/analysis/src/sensitivity.rs`)
//! to a swept-frequency formulation: for each parameter `p` and each
//! frequency `f` in the AC sweep, compute the forward-difference sensitivity
//! of the magnitude (and phase) of the output node voltage to perturbations
//! in `p`.
//!
//! Algorithm (forward differences in the AC admittance solve):
//!   for each frequency f:
//!     - solve the baseline AC system → V0(f) at the output node
//!     - for each parameter p:
//!         - perturb p ← p + h
//!         - re-solve AC system (re-uses the same factorisation pipeline)
//!         - compute (V_h(f) - V0(f)) / h → magnitude / phase derivatives
//!
//! The implementation reuses `incspice_analysis::run_ac` so the heavy lifting
//! (DC OP, frequency sweep, complex block solve) lives in one place and we
//! only orchestrate the perturbations here.

use incspice_core::{Circuit, DeviceKind, SimError, SimOptions};
use incspice_solver::device::DeviceRegistry;

use crate::ac::{AcConfig, run_ac, run_ac_with_options};
use crate::result::AcResult;

/// Sensitivity output specifier (mirrors the DC variant).
#[derive(Debug, Clone)]
pub enum SensAcOutput {
    /// Node voltage `V(name)`.
    NodeVoltage(String),
}

/// Configuration for an AC sensitivity sweep.
#[derive(Debug, Clone)]
pub struct SensAcConfig {
    /// AC sweep configuration (frequency range, sweep type, point count).
    pub ac: AcConfig,
    /// Output variable.
    pub output: SensAcOutput,
    /// Device names whose primary parameter is perturbed.
    pub params: Vec<String>,
}

/// Per-parameter, per-frequency sensitivity entry.
#[derive(Debug, Clone)]
pub struct SensAcEntry {
    /// Device name being perturbed.
    pub param_name: String,
    /// Absolute magnitude sensitivity `d|V|/dp` per frequency.
    pub d_magnitude: Vec<f64>,
    /// Absolute phase sensitivity `dphase/dp` (radians) per frequency.
    pub d_phase: Vec<f64>,
}

/// Result of an AC sensitivity analysis.
#[derive(Debug, Clone)]
pub struct SensAcResult {
    /// Frequencies that match the baseline AC sweep.
    pub frequencies: Vec<f64>,
    /// Baseline magnitude at the output node, one entry per frequency.
    pub baseline_mag: Vec<f64>,
    /// Baseline phase (radians) at the output node, one entry per frequency.
    pub baseline_phase: Vec<f64>,
    /// Per-parameter sensitivity entries.
    pub entries: Vec<SensAcEntry>,
}

/// Run an AC sensitivity sweep with default options.
pub fn run_sens_ac(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &SensAcConfig,
) -> Result<SensAcResult, SimError> {
    run_sens_ac_inner(circuit, registry, cfg, None)
}

/// Run an AC sensitivity sweep with explicit `.OPTIONS`.
pub fn run_sens_ac_with_options(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &SensAcConfig,
    opts: &SimOptions,
) -> Result<SensAcResult, SimError> {
    run_sens_ac_inner(circuit, registry, cfg, Some(opts))
}

fn run_sens_ac_inner(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &SensAcConfig,
    opts: Option<&SimOptions>,
) -> Result<SensAcResult, SimError> {
    // 1. Baseline AC sweep.
    let base = ac_run(circuit, registry, &cfg.ac, opts)?;

    // 2. Resolve output node index in the AcResult node ordering. We map by
    //    iterating circuit nodes in their topological order and matching the
    //    requested name. The AcResult stores `node_magnitudes[freq][node_idx]`
    //    where `node_idx` runs over the circuit's non-ground nodes.
    let SensAcOutput::NodeVoltage(out_name) = &cfg.output;
    let out_idx = node_index(circuit, out_name)?;

    let frequencies = base.frequencies.clone();
    let nf = frequencies.len();

    let baseline_mag: Vec<f64> = base.node_magnitudes.iter().map(|m| m[out_idx]).collect();
    let baseline_phase: Vec<f64> = base.node_phases.iter().map(|p| p[out_idx]).collect();

    // 3. Per-parameter forward differences.
    let entries = cfg
        .params
        .iter()
        .map(|param_name| -> Result<SensAcEntry, SimError> {
            let dev = circuit.find_device(param_name).ok_or_else(|| {
                SimError::Parse(format!("SENS AC: device '{param_name}' not found"))
            })?;
            let (param_key, p0) = primary_param(dev.kind, &dev.params)?;
            let h = perturbation(p0);

            let mut perturbed = circuit.clone();
            perturbed.set_device_param(param_name, &param_key, p0 + h);
            let pert = ac_run(&perturbed, registry, &cfg.ac, opts)?;

            // The perturbed sweep may have generated a different number of
            // points if the user passes a non-integer decade count. We
            // truncate to the minimum to stay safe.
            let m = nf.min(pert.frequencies.len());
            let d_magnitude: Vec<f64> = (0..m)
                .map(|i| (pert.node_magnitudes[i][out_idx] - baseline_mag[i]) / h)
                .collect();
            let d_phase: Vec<f64> = (0..m)
                .map(|i| (pert.node_phases[i][out_idx] - baseline_phase[i]) / h)
                .collect();
            Ok(SensAcEntry {
                param_name: param_name.clone(),
                d_magnitude,
                d_phase,
            })
        })
        .collect::<Result<Vec<_>, _>>()?;

    Ok(SensAcResult {
        frequencies,
        baseline_mag,
        baseline_phase,
        entries,
    })
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn ac_run(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &AcConfig,
    opts: Option<&SimOptions>,
) -> Result<AcResult, SimError> {
    match opts {
        Some(o) => run_ac_with_options(circuit, registry, cfg, o),
        None => run_ac(circuit, registry, cfg),
    }
}

fn node_index(circuit: &Circuit, name: &str) -> Result<usize, SimError> {
    let lower = name.to_lowercase();
    let id = circuit
        .find_node(&lower)
        .ok_or_else(|| SimError::Parse(format!("SENS AC: node '{name}' not found")))?;
    let raw = id.index() as usize;
    if raw == 0 {
        return Err(SimError::Parse(
            "SENS AC: cannot use ground as output".into(),
        ));
    }
    Ok(raw - 1)
}

fn perturbation(p0: f64) -> f64 {
    f64::max(1e-8, 1e-3 * p0.abs())
}

fn primary_param(
    kind: DeviceKind,
    params: &incspice_core::ParamMap,
) -> Result<(String, f64), SimError> {
    let key = match kind {
        DeviceKind::Resistor => "resistance",
        DeviceKind::Capacitor => "capacitance",
        DeviceKind::Inductor => "inductance",
        DeviceKind::VoltageSource => "dc",
        DeviceKind::CurrentSource => "dc",
        _ => {
            return Err(SimError::Parse(format!(
                "SENS AC: unsupported device kind {kind:?}"
            )));
        }
    };
    let val = params
        .get(key)
        .ok_or_else(|| SimError::Parse(format!("SENS AC: device has no '{key}' parameter")))?;
    Ok((key.to_string(), val))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ac::AcSweepType;
    use incspice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};

    fn rc_lowpass(r: f64, c: f64) -> Circuit {
        let mut ckt = Circuit::new();
        let n_in = ckt.add_node("in");
        let n_out = ckt.add_node("out");
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "Vin",
                DeviceKind::VoltageSource,
                &[(0, n_in), (1, NodeId::GROUND)],
            )
            .with_param("dc", 0.0)
            .with_param("ac_mag", 1.0),
        );
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "R1",
                DeviceKind::Resistor,
                &[(0, n_in), (1, n_out)],
            )
            .with_param("resistance", r),
        );
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "C1",
                DeviceKind::Capacitor,
                &[(0, n_out), (1, NodeId::GROUND)],
            )
            .with_param("capacitance", c),
        );
        ckt.build_topology();
        ckt
    }

    #[test]
    fn sens_ac_runs_on_rc_lowpass() {
        let ckt = rc_lowpass(1e3, 1e-9);
        let reg = DeviceRegistry::new_default();
        let cfg = SensAcConfig {
            ac: AcConfig::new(1e3, 1e6, 5, AcSweepType::Decade),
            output: SensAcOutput::NodeVoltage("out".into()),
            params: vec!["R1".into(), "C1".into()],
        };
        let res = run_sens_ac(&ckt, &reg, &cfg).unwrap();
        assert!(!res.frequencies.is_empty());
        assert_eq!(res.entries.len(), 2);
        for entry in &res.entries {
            assert_eq!(entry.d_magnitude.len(), res.frequencies.len());
            assert_eq!(entry.d_phase.len(), res.frequencies.len());
        }
    }
}
