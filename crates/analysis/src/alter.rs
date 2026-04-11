//! `.ALTER` section driver — N.3.4.
//!
//! SPICE `.ALTER` re-runs an analysis with a patched set of model or
//! instance parameters.  Each block has an optional title and a list of
//! parameter overrides expressed as `(device_or_model, param, value)` triples.
//!
//! ## Usage
//!
//! ```rust,ignore
//! use bigospice_analysis::alter::{AlterBlock, AlterParam, run_alter};
//! use bigospice_analysis::dc_op::run_dc_op;
//!
//! let blocks = vec![
//!     AlterBlock::new("run2")
//!         .with_param(AlterParam::device("R1", "resistance", 2e3)),
//! ];
//! let results = run_alter(&base_circuit, &registry, &blocks, |ckt, reg| {
//!     run_dc_op(ckt, reg).map_err(|e| e.to_string())
//! })?;
//! ```
//!
//! ## Design
//!
//! - Each [`AlterBlock`] clones the base circuit and applies its overrides
//!   via [`Circuit::set_device_param`] before invoking the analysis closure.
//! - The base circuit is run first (index 0); each alter block occupies
//!   indices 1..=N in the returned [`Vec<AlterResult>`].
//! - No parser integration yet — the caller supplies `AlterBlock` values
//!   directly.  The parser agent can convert `.ALTER` AST nodes into this
//!   type.

use bigospice_core::{Circuit, SimError};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// One device/model parameter override for an `.ALTER` block.
#[derive(Debug, Clone)]
pub struct AlterParam {
    /// Device name (e.g. `"R1"`, `"M1"`).
    pub device_name: String,
    /// Parameter key (e.g. `"resistance"`, `"vth0"`).
    pub param_key: String,
    /// New parameter value.
    pub value: f64,
}

impl AlterParam {
    /// Construct a device parameter override.
    pub fn device(
        device_name: impl Into<String>,
        param_key: impl Into<String>,
        value: f64,
    ) -> Self {
        Self {
            device_name: device_name.into(),
            param_key: param_key.into(),
            value,
        }
    }
}

/// One `.ALTER` block: an optional title plus a list of parameter overrides.
#[derive(Debug, Clone)]
pub struct AlterBlock {
    /// Optional run title (mirrors SPICE `.ALTER run2` syntax).
    pub title: Option<String>,
    /// Parameter overrides applied to the circuit before re-running.
    pub params: Vec<AlterParam>,
}

impl AlterBlock {
    /// Create an empty block with a title.
    pub fn new(title: impl Into<String>) -> Self {
        Self {
            title: Some(title.into()),
            params: Vec::new(),
        }
    }

    /// Create an untitled block.
    pub fn untitled() -> Self {
        Self { title: None, params: Vec::new() }
    }

    /// Add a parameter override (builder style).
    pub fn with_param(mut self, p: AlterParam) -> Self {
        self.params.push(p);
        self
    }

    /// Apply all overrides to a circuit clone, returning the mutated clone.
    ///
    /// Parameters that do not match any device are silently ignored (matches
    /// SPICE behaviour: `.ALTER` blocks often override model params that may
    /// not all be in scope for every sub-circuit).
    pub fn apply_to(&self, base: &Circuit) -> Circuit {
        let mut ckt = base.clone();
        for p in &self.params {
            ckt.set_device_param(&p.device_name, &p.param_key, p.value);
        }
        ckt
    }
}

/// Result of one analysis run (base or alter block).
#[derive(Debug)]
pub struct AlterResult<T> {
    /// Run index: 0 = base circuit, 1..=N = alter blocks.
    pub run_index: usize,
    /// Title from the alter block, or `"base"` for run 0.
    pub title: String,
    /// Analysis output, or an error message if the run failed.
    pub output: Result<T, String>,
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

/// Run the base circuit once, then re-run for each `.ALTER` block.
///
/// `eval` is called with a circuit clone and must return `Ok(T)` or
/// `Err(message)`.  Failures do not abort subsequent runs.
///
/// The first entry in the returned vec is always the base-circuit run
/// (index 0, title `"base"`).
pub fn run_alter<T, F>(
    base_circuit: &Circuit,
    alter_blocks: &[AlterBlock],
    mut eval: F,
) -> Result<Vec<AlterResult<T>>, SimError>
where
    F: FnMut(&Circuit) -> Result<T, String>,
{
    let total = 1 + alter_blocks.len();
    let mut results = Vec::with_capacity(total);

    // Run 0: base circuit
    let base_output = eval(base_circuit).map_err(|e| e.to_string());
    // Re-map to not abort on eval errors
    let base_output = match base_output {
        Ok(v) => Ok(v),
        Err(e) => Err(e),
    };
    results.push(AlterResult {
        run_index: 0,
        title: "base".to_string(),
        output: base_output,
    });

    // Runs 1..N: alter blocks
    for (i, block) in alter_blocks.iter().enumerate() {
        let patched = block.apply_to(base_circuit);
        let output = eval(&patched).map_err(|e| e.to_string());
        let title = block
            .title
            .clone()
            .unwrap_or_else(|| format!("alter_{}", i + 1));
        results.push(AlterResult {
            run_index: i + 1,
            title,
            output,
        });
    }

    Ok(results)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use bigospice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
    use bigospice_device::DeviceRegistry;

    fn voltage_divider(r1: f64) -> Circuit {
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
            .with_param("resistance", r1),
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
    fn alter_changes_resistor_value() {
        let base = voltage_divider(1000.0);
        let reg = DeviceRegistry::new_default();

        let block = AlterBlock::new("run2").with_param(AlterParam::device("R1", "resistance", 2000.0));

        let results = run_alter(&base, &[block], |ckt| {
            crate::dc_op::run_dc_op(ckt, &reg)
                .map(|out| {
                    out.result.node_voltages
                        .iter()
                        .find(|(n, _)| n == "2")
                        .map(|(_, v)| *v)
                        .unwrap_or(0.0)
                })
                .map_err(|e| e.to_string())
        })
        .unwrap();

        assert_eq!(results.len(), 2);

        // Base: R1=1k, R2=1k → V(2) = 5 * 1000/2000 = 2.5 V
        let v_base = *results[0].output.as_ref().unwrap();
        assert!((v_base - 2.5).abs() < 1e-6, "base V(2)={v_base}");

        // Alter: R1=2k, R2=1k → V(2) = 5 * 1000/3000 = 1.667 V
        let v_alter = *results[1].output.as_ref().unwrap();
        assert!((v_alter - 5.0 / 3.0).abs() < 1e-4, "alter V(2)={v_alter}");

        assert_eq!(results[1].title, "run2");
    }

    #[test]
    fn alter_apply_to_clones_base() {
        let base = voltage_divider(1000.0);
        let block = AlterBlock::new("x").with_param(AlterParam::device("R1", "resistance", 999.0));
        let patched = block.apply_to(&base);
        // Base unchanged
        let r_base = base.find_device("R1").unwrap().params.get("resistance").unwrap();
        let r_patch = patched.find_device("R1").unwrap().params.get("resistance").unwrap();
        assert!((r_base - 1000.0).abs() < 1e-9);
        assert!((r_patch - 999.0).abs() < 1e-9);
    }

    #[test]
    fn run_alter_base_always_first() {
        let base = voltage_divider(500.0);
        let results = run_alter::<f64, _>(&base, &[], |_ckt| Ok(42.0)).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].run_index, 0);
        assert_eq!(results[0].title, "base");
        assert_eq!(*results[0].output.as_ref().unwrap(), 42.0);
    }
}
