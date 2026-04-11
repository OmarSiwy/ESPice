//! Reliability/Aging analysis (`.ROL`) — Wave W.4.
//!
//! Models electromigration (EM), NBTI, and HCI wearout for
//! circuit reliability simulation (Xyce-compatible).
//!
//! # Physical models
//!
//! ## Electromigration (Black's equation)
//! ```text
//! MTTF = A * J^(-n) * exp(Ea / (k * T))
//! ```
//! Where `J` is current density [A/m²], `n = 1.8`, `Ea = 0.9 eV` (Al),
//! `k = 8.617e-5 eV/K`. `A` is normalised so MTTF = 1e9 s at J = 1e10 A/m²,
//! T = 358.15 K.
//!
//! ## NBTI (simplified sqrt-t model)
//! ```text
//! ΔVth = A_nbti * sqrt(t) * exp(-Ea_nbti / (k*T))
//! ```
//! With `A_nbti = 0.01`, `Ea_nbti = 0.15 eV`. Applied to pMOS devices only.
//!
//! ## HCI (stub)
//! Returns 0.0 drain-current degradation fraction for nMOS devices.

use bigospice_core::{Circuit, DeviceKind, SimError};
use crate::result::DcOpResult;

// Re-export RolConfig from bigospice_core so callers can use it via this crate.
pub use bigospice_core::RolConfig;

// ---------------------------------------------------------------------------
// Physical constants
// ---------------------------------------------------------------------------

/// Boltzmann constant [eV/K].
const KB_EV: f64 = 8.617_333_262e-5;

// ---------------------------------------------------------------------------
// Black's equation constants (aluminium interconnect defaults)
// ---------------------------------------------------------------------------

/// Current-density exponent (Black's n, typical Al).
const EM_N: f64 = 1.8;
/// Activation energy [eV] for Al EM.
const EM_EA: f64 = 0.9;
/// Reference conditions for normalisation: J = 1e10 A/m², T = 358.15 K.
const EM_J_REF: f64 = 1.0e10;
const EM_T_REF: f64 = 358.15;
/// Pre-exponential A, chosen so MTTF = 1e9 s at (J_REF, T_REF).
///
/// A = MTTF_target / (J_REF^(-n) * exp(Ea/(k*T_REF)))
fn em_prefactor_a() -> f64 {
    let mttf_target = 1.0e9_f64;
    let arrhenius = (EM_EA / (KB_EV * EM_T_REF)).exp();
    let j_term = EM_J_REF.powf(-EM_N);
    mttf_target / (j_term * arrhenius)
}

// ---------------------------------------------------------------------------
// NBTI constants
// ---------------------------------------------------------------------------

const NBTI_A: f64 = 0.01;
const NBTI_EA: f64 = 0.15;

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

/// Per-device degradation result from a `.ROL` analysis.
#[derive(Debug, Clone)]
pub struct DeviceDegradation {
    /// Instance name, e.g. `"R1"`.
    pub device_name: String,
    /// Electromigration MTTF [s] via Black's equation (resistors/wires only).
    /// `None` when EM is disabled or the device kind is not applicable.
    pub em_mttf: Option<f64>,
    /// NBTI threshold-voltage shift [V] after `cfg.lifetime` (pMOS only).
    /// `None` when NBTI is disabled or the device is not pMOS.
    pub nbti_dvth: Option<f64>,
    /// HCI drain-current degradation [fraction] after `cfg.lifetime` (nMOS only).
    /// `None` when HCI is disabled or the device is not nMOS.
    /// Currently a stub that always returns `0.0` when enabled.
    pub hci_delta_id: Option<f64>,
}

/// Full result of a `.ROL` reliability analysis.
#[derive(Debug, Clone, Default)]
pub struct RolResult {
    /// Per-device degradation entries, one per applicable circuit device.
    pub devices: Vec<DeviceDegradation>,
    /// Minimum EM MTTF across all devices — the weakest-link lifetime [s].
    /// `None` when no EM results are available.
    pub min_em_mttf: Option<f64>,
}

// ---------------------------------------------------------------------------
// Physical model kernels
// ---------------------------------------------------------------------------

/// Black's equation: MTTF = A * J^(-n) * exp(Ea / (k*T)).
///
/// `current_a` is the DC branch current [A].
/// Wire cross-section is assumed 1 µm² (1e-12 m²) as a reasonable default
/// for a schematic-level analysis where geometry is not known.
fn black_mttf(current_a: f64, temp_k: f64) -> f64 {
    const WIRE_AREA_M2: f64 = 1.0e-12; // 1 µm²
    let j = current_a.abs() / WIRE_AREA_M2;
    // Guard against J = 0 (open-circuit resistors): infinite lifetime.
    if j < 1.0e-30 {
        return f64::INFINITY;
    }
    let a = em_prefactor_a();
    a * j.powf(-EM_N) * (EM_EA / (KB_EV * temp_k)).exp()
}

/// Simplified NBTI ΔVth model: A_nbti * sqrt(t) * exp(-Ea_nbti / (k*T)).
fn nbti_dvth(lifetime_s: f64, temp_k: f64) -> f64 {
    NBTI_A * lifetime_s.sqrt() * (-(NBTI_EA) / (KB_EV * temp_k)).exp()
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Run a `.ROL` reliability/aging analysis.
///
/// Takes the DC operating-point result (for branch currents) and the circuit
/// topology (for device kinds), and computes per-device degradation metrics
/// over `cfg.lifetime` seconds at `cfg.temp` kelvin.
///
/// # Errors
///
/// Returns [`SimError::Analysis`] when the configuration is physically
/// invalid (e.g. `lifetime <= 0` or `temp <= 0`).
pub fn run_rol(
    dc_result: &DcOpResult,
    ckt: &Circuit,
    cfg: &RolConfig,
) -> Result<RolResult, SimError> {
    if cfg.lifetime <= 0.0 {
        return Err(SimError::Analysis(
            "ROL: lifetime must be positive".into(),
        ));
    }
    if cfg.temp <= 0.0 {
        return Err(SimError::Analysis(
            "ROL: temperature must be positive (Kelvin)".into(),
        ));
    }

    // Build a name→current lookup from the DC OP branch-current table.
    // Branch currents are keyed by device name (lowercase).
    let branch_lookup: std::collections::HashMap<&str, f64> = dc_result
        .branch_currents
        .iter()
        .map(|(name, cur)| (name.as_str(), *cur))
        .collect();

    // For resistors we approximate the current from node-voltage difference
    // when branch current is not directly recorded (resistors don't get a
    // dedicated MNA branch variable in BigOSpice — only V-sources and inductors do).
    // We store node voltages by name for that fallback.
    let node_lookup: std::collections::HashMap<&str, f64> = dc_result
        .node_voltages
        .iter()
        .map(|(name, v)| (name.as_str(), *v))
        .collect();

    let mut degradations: Vec<DeviceDegradation> = Vec::with_capacity(ckt.devices().len());

    for dev in ckt.devices() {
        let name_lower = dev.name.to_lowercase();

        let em_mttf = if cfg.em_enabled && dev.kind == DeviceKind::Resistor {
            // Try branch current first; fall back to V/R estimate.
            let current = branch_lookup
                .get(name_lower.as_str())
                .copied()
                .unwrap_or_else(|| {
                    // Estimate I = (V+ - V-) / R from node voltages.
                    let r = dev.params.get("resistance").unwrap_or(1.0);
                    if dev.terminals.len() >= 2 {
                        let vp = dev.terminals[0].node;
                        let vn = dev.terminals[1].node;
                        let node_name_p = ckt.nodes()
                            .iter()
                            .find(|n| n.id == vp)
                            .map(|n| n.name.as_str())
                            .unwrap_or("0");
                        let node_name_n = ckt.nodes()
                            .iter()
                            .find(|n| n.id == vn)
                            .map(|n| n.name.as_str())
                            .unwrap_or("0");
                        let vplus = if node_name_p == "0" || node_name_p == "gnd" {
                            0.0
                        } else {
                            node_lookup.get(node_name_p).copied().unwrap_or(0.0)
                        };
                        let vminus = if node_name_n == "0" || node_name_n == "gnd" {
                            0.0
                        } else {
                            node_lookup.get(node_name_n).copied().unwrap_or(0.0)
                        };
                        (vplus - vminus) / r
                    } else {
                        0.0
                    }
                });
            Some(black_mttf(current, cfg.temp))
        } else {
            None
        };

        let nbti_dvth_val = if cfg.nbti_enabled && dev.kind == DeviceKind::MosfetP {
            Some(nbti_dvth(cfg.lifetime, cfg.temp))
        } else {
            None
        };

        let hci_delta_id = if cfg.hci_enabled && dev.kind == DeviceKind::MosfetN {
            // Stub: HCI model not yet implemented; returns 0.0 degradation.
            Some(0.0_f64)
        } else {
            None
        };

        if em_mttf.is_some() || nbti_dvth_val.is_some() || hci_delta_id.is_some() {
            degradations.push(DeviceDegradation {
                device_name: dev.name.clone(),
                em_mttf,
                nbti_dvth: nbti_dvth_val,
                hci_delta_id,
            });
        }
    }

    // Weakest-link EM lifetime.
    let min_em_mttf = degradations
        .iter()
        .filter_map(|d| d.em_mttf)
        .filter(|v| v.is_finite())
        .reduce(f64::min);

    Ok(RolResult {
        devices: degradations,
        min_em_mttf,
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use bigospice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
    use bigospice_device::DeviceRegistry;
    use crate::dc_op::run_dc_op;

    fn two_resistor_circuit() -> Circuit {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let n2 = ckt.add_node("2");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)]).with_param("dc", 5.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "R1", DeviceKind::Resistor,
                &[(0, n1), (1, n2)]).with_param("resistance", 1000.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "R2", DeviceKind::Resistor,
                &[(0, n2), (1, NodeId::GROUND)]).with_param("resistance", 1000.0),
        );
        ckt.build_topology();
        ckt
    }

    /// EM MTTF must be a positive finite number for resistors carrying current.
    #[test]
    fn rol_em_basic() {
        let ckt = two_resistor_circuit();
        let reg = DeviceRegistry::new_default();
        let dc_out = run_dc_op(&ckt, &reg).unwrap();

        let cfg = RolConfig::default();
        let result = run_rol(&dc_out.result, &ckt, &cfg).unwrap();

        // Both R1 and R2 should have EM entries.
        let em_entries: Vec<_> = result.devices.iter()
            .filter_map(|d| d.em_mttf)
            .collect();
        assert!(!em_entries.is_empty(), "expected EM entries for resistors");

        for mttf in &em_entries {
            assert!(*mttf > 0.0 && mttf.is_finite(),
                "MTTF={mttf} should be positive and finite");
        }

        assert!(result.min_em_mttf.is_some());
        assert!(result.min_em_mttf.unwrap() > 0.0);
    }

    /// Higher temperature → shorter EM MTTF (Arrhenius relationship).
    #[test]
    fn rol_em_temperature_dependence() {
        let ckt = two_resistor_circuit();
        let reg = DeviceRegistry::new_default();
        let dc_out = run_dc_op(&ckt, &reg).unwrap();

        let cfg_cool = RolConfig { temp: 300.0, ..RolConfig::default() };
        let cfg_hot  = RolConfig { temp: 400.0, ..RolConfig::default() };

        let res_cool = run_rol(&dc_out.result, &ckt, &cfg_cool).unwrap();
        let res_hot  = run_rol(&dc_out.result, &ckt, &cfg_hot).unwrap();

        let mttf_cool = res_cool.min_em_mttf.unwrap();
        let mttf_hot  = res_hot.min_em_mttf.unwrap();

        assert!(mttf_hot < mttf_cool,
            "hotter temperature should give shorter MTTF: cool={mttf_cool:.3e} hot={mttf_hot:.3e}");
    }

    /// Zero lifetime is rejected as invalid.
    #[test]
    fn rol_invalid_lifetime() {
        let ckt = two_resistor_circuit();
        let reg = DeviceRegistry::new_default();
        let dc_out = run_dc_op(&ckt, &reg).unwrap();
        let cfg = RolConfig { lifetime: 0.0, ..RolConfig::default() };
        assert!(run_rol(&dc_out.result, &ckt, &cfg).is_err());
    }

    /// Zero temperature is rejected.
    #[test]
    fn rol_invalid_temperature() {
        let ckt = two_resistor_circuit();
        let reg = DeviceRegistry::new_default();
        let dc_out = run_dc_op(&ckt, &reg).unwrap();
        let cfg = RolConfig { temp: 0.0, ..RolConfig::default() };
        assert!(run_rol(&dc_out.result, &ckt, &cfg).is_err());
    }

    /// NBTI ΔVth increases with lifetime (sqrt-t model).
    #[test]
    fn rol_nbti_grows_with_time() {
        let dvth_short = nbti_dvth(1.0e6, 358.15);
        let dvth_long  = nbti_dvth(1.0e9, 358.15);
        assert!(dvth_long > dvth_short,
            "NBTI ΔVth should grow with time: short={dvth_short:.4e} long={dvth_long:.4e}");
        assert!(dvth_short > 0.0);
    }
}
